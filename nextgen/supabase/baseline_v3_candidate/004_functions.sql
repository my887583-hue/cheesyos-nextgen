-- CHEESYOS NEXTGEN BASELINE V3 CANDIDATE: FUNCTIONS & RPCS
-- Target Project: sdbnibyzqtgpbexlznat

CREATE OR REPLACE FUNCTION public.sync_users_legacy_fields()
RETURNS TRIGGER AS $$
BEGIN
    -- Sync mobile to phone and vice versa
    IF NEW.mobile IS NOT NULL AND NEW.phone IS NULL THEN
        NEW.phone := NEW.mobile;
    ELSIF NEW.phone IS NOT NULL AND NEW.mobile IS NULL THEN
        NEW.mobile := NEW.phone;
    END IF;

    -- Sync full_name to name and vice versa
    IF NEW.full_name IS NOT NULL AND NEW.name IS NULL THEN
        NEW.name := NEW.full_name;
    ELSIF NEW.name IS NOT NULL AND NEW.full_name IS NULL THEN
        NEW.full_name := NEW.name;
    END IF;

    -- If both are set but different, prioritize mobile/full_name
    IF NEW.mobile IS NOT NULL AND NEW.phone IS NOT NULL AND NEW.mobile <> NEW.phone THEN
        NEW.phone := NEW.mobile;
    END IF;
    IF NEW.full_name IS NOT NULL AND NEW.name IS NOT NULL AND NEW.full_name <> NEW.name THEN
        NEW.name := NEW.full_name;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.secure_internal_login(
    p_login_id TEXT, -- Email, Mobile, or Employee Code
    p_password TEXT,
    p_device TEXT,
    p_ip TEXT,
    p_location TEXT
)
RETURNS JSONB AS $$
DECLARE
    v_user RECORD;
    v_token TEXT;
    v_expires TIMESTAMPTZ;
    v_payload JSONB;
    v_test_hash TEXT;
BEGIN
    -- Query user table
    SELECT * INTO v_user 
    FROM public.users 
    WHERE (email = p_login_id OR mobile = p_login_id OR employee_code = p_login_id)
      AND role != 'customer'
      AND status = 'active'
    LIMIT 1;

    IF v_user IS NULL THEN
        -- Log failed login event
        INSERT INTO public.security_events (event_type, severity, description, ip_address, device, location)
        VALUES ('failed_login', 'medium', 'Attempted login with non-existent or inactive ID: ' || p_login_id, p_ip, p_device, p_location);
        
        RETURN jsonb_build_object('success', false, 'error', 'Invalid login credentials');
    END IF;

    -- Standardize hash prefix for pgcrypto support ($2b$ -> $2a$)
    v_test_hash := REPLACE(v_user.password_hash, '$2b$', '$2a$');

    -- Verify password hash using pgcrypto's crypt function
    IF v_test_hash IS NULL OR v_test_hash <> extensions.crypt(p_password, v_test_hash) THEN
        -- Log failed password attempt
        INSERT INTO public.security_events (user_id, event_type, severity, description, ip_address, device, location)
        VALUES (v_user.id, 'failed_login', 'medium', 'Invalid password for user: ' || v_user.email, p_ip, p_device, p_location);
        
        RETURN jsonb_build_object('success', false, 'error', 'Invalid login credentials');
    END IF;

    -- Generate random secure token
    v_token := encode(extensions.gen_random_bytes(32), 'hex');
    v_expires := NOW() + INTERVAL '24 hours';

    -- Insert active session
    INSERT INTO public.active_sessions (user_id, token, ip_address, device, location, expires_at)
    VALUES (v_user.id, v_token, p_ip, p_device, p_location, v_expires);

    -- Log successful login
    INSERT INTO public.security_events (user_id, event_type, severity, description, ip_address, device, location)
    VALUES (v_user.id, 'successful_login', 'low', 'User logged in successfully', p_ip, p_device, p_location);

    -- Check if user is logged into multiple devices concurrently
    DECLARE
        v_active_devices_count INT;
    BEGIN
        SELECT COUNT(DISTINCT device) INTO v_active_devices_count 
        FROM public.active_sessions 
        WHERE user_id = v_user.id AND expires_at > NOW();

        IF v_active_devices_count > 1 THEN
            INSERT INTO public.security_alerts (user_id, alert_type, description)
            VALUES (v_user.id, 'multiple_devices', 'User ' || v_user.full_name || ' has sessions active on ' || v_active_devices_count || ' separate devices.');
        END IF;
    END;

    -- Return authentication payload
    v_payload := jsonb_build_object(
        'success', true,
        'token', v_token,
        'user', jsonb_build_object(
            'id', v_user.id,
            'full_name', v_user.full_name,
            'email', v_user.email,
            'mobile', v_user.mobile,
            'role', v_user.role,
            'branch_id', v_user.branch_id,
            'employee_code', v_user.employee_code
        )
    );

    RETURN v_payload;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.secure_get_session(p_token TEXT)
RETURNS JSONB AS $$
DECLARE
    v_session RECORD;
    v_user RECORD;
    v_roles JSONB;
BEGIN
    SELECT * INTO v_session 
    FROM public.active_sessions 
    WHERE token = p_token AND expires_at > NOW() 
    LIMIT 1;

    IF v_session IS NULL THEN
        RETURN jsonb_build_object('valid', false);
    END IF;

    SELECT * INTO v_user 
    FROM public.users 
    WHERE id = v_session.user_id 
    LIMIT 1;

    IF v_user IS NULL THEN
        RETURN jsonb_build_object('valid', false);
    END IF;

    SELECT COALESCE(jsonb_agg(role), '[]'::jsonb) INTO v_roles 
    FROM public.user_roles 
    WHERE user_id = v_user.id AND is_active = true;

    RETURN jsonb_build_object(
        'valid', true,
        'session_id', v_session.id,
        'user', jsonb_build_object(
            'id', v_user.id,
            'full_name', v_user.full_name,
            'email', v_user.email,
            'mobile', v_user.mobile,
            'role', v_user.role,
            'branch_id', v_user.branch_id,
            'employee_code', v_user.employee_code,
            'roles', v_roles
        )
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.secure_validate_coupon(
    p_code TEXT,
    p_subtotal NUMERIC,
    p_user_id BIGINT
)
RETURNS JSONB AS $$
DECLARE
    v_coupon RECORD;
    v_user_orders_count INT;
    v_overall_orders_count INT;
    v_user_usage_count INT;
    v_user_phone TEXT;
    v_user_mobile TEXT;
    v_user_email TEXT;
BEGIN
    -- Query the coupons table
    SELECT * INTO v_coupon 
    FROM public.coupons 
    WHERE code = p_code AND active = TRUE 
    LIMIT 1;

    -- If not found in coupons, fallback check on legacy offers table
    IF v_coupon IS NULL THEN
        DECLARE
            v_offer RECORD;
        BEGIN
            SELECT * INTO v_offer 
            FROM public.offers 
            WHERE code = p_code AND active = TRUE 
            LIMIT 1;

            IF v_offer IS NULL THEN
                RETURN jsonb_build_object('valid', false, 'error', 'Invalid or inactive coupon code');
            END IF;

            -- Convert legacy offer structure dynamically to unified record format
            v_coupon.id := v_offer.id;
            v_coupon.code := v_offer.code;
            v_coupon.discount_type := v_offer.discount_type;
            v_coupon.discount_value := COALESCE(v_offer.discount_value, 0.0);
            v_coupon.max_discount := v_offer.max_discount;
            v_coupon.min_order := COALESCE(v_offer.min_order, 0.0);
            v_coupon.expiry_date := v_offer.expiry_date;
            v_coupon.usage_limit := v_offer.usage_limit;
            v_coupon.user_usage_limit := v_offer.user_usage_limit;
            v_coupon.user_type := v_offer.user_type;
            v_coupon.specific_users := v_offer.specific_users;
        END;
    END IF;

    -- 1. Expiry check
    IF v_coupon.expiry_date IS NOT NULL AND v_coupon.expiry_date < NOW() THEN
        RETURN jsonb_build_object('valid', false, 'error', 'This coupon has expired');
    END IF;

    -- 2. Minimum order check
    IF p_subtotal < v_coupon.min_order THEN
        RETURN jsonb_build_object('valid', false, 'error', 'Minimum order amount for this coupon is ₹' || v_coupon.min_order);
    END IF;

    -- Fetch user phone, mobile, and email for specific target validation
    IF p_user_id IS NOT NULL THEN
        SELECT phone, mobile, email INTO v_user_phone, v_user_mobile, v_user_email 
        FROM public.users 
        WHERE id = p_user_id;
    END IF;

    -- 3. Specific user check (checking user ID, phone, mobile, and email)
    IF v_coupon.user_type = 'specific' THEN
        IF p_user_id IS NULL OR v_coupon.specific_users IS NULL OR (
            NOT (v_coupon.specific_users LIKE '%' || p_user_id::text || '%') AND
            (v_user_phone IS NULL OR NOT (v_coupon.specific_users LIKE '%' || v_user_phone || '%')) AND
            (v_user_mobile IS NULL OR NOT (v_coupon.specific_users LIKE '%' || v_user_mobile || '%')) AND
            (v_user_email IS NULL OR NOT (LOWER(v_coupon.specific_users) LIKE '%' || LOWER(v_user_email) || '%'))
        ) THEN
            RETURN jsonb_build_object('valid', false, 'error', 'This coupon is not valid for your account');
        END IF;
    END IF;

    -- 4. New/Existing user eligibility check
    IF v_coupon.user_type IN ('new_users', 'existing_users') THEN
        SELECT COUNT(*) INTO v_user_orders_count 
        FROM public.orders 
        WHERE user_id = p_user_id AND status <> 'Cancelled';

        IF v_coupon.user_type = 'new_users' AND v_user_orders_count > 0 THEN
            RETURN jsonb_build_object('valid', false, 'error', 'This coupon is only valid for your first order');
        END IF;

        IF v_coupon.user_type = 'existing_users' AND v_user_orders_count = 0 THEN
            RETURN jsonb_build_object('valid', false, 'error', 'This coupon is only valid for repeat customers');
        END IF;
    END IF;

    -- 5. Overall usage limit check
    IF v_coupon.usage_limit IS NOT NULL THEN
        SELECT COUNT(*) INTO v_overall_orders_count 
        FROM public.orders 
        WHERE coupon_code = p_code AND status <> 'Cancelled';

        IF v_overall_orders_count >= v_coupon.usage_limit THEN
            RETURN jsonb_build_object('valid', false, 'error', 'This coupon has reached its maximum usage limit');
        END IF;
    END IF;

    -- 6. Per-user usage limit check
    IF v_coupon.user_usage_limit IS NOT NULL THEN
        SELECT COUNT(*) INTO v_user_usage_count 
        FROM public.orders 
        WHERE user_id = p_user_id AND coupon_code = p_code AND status <> 'Cancelled';

        IF v_user_usage_count >= v_coupon.user_usage_limit THEN
            RETURN jsonb_build_object('valid', false, 'error', 'You have already used this coupon ' || v_coupon.user_usage_limit || ' times');
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'valid', true,
        'coupon_id', v_coupon.id,
        'discount_type', v_coupon.discount_type,
        'discount_value', v_coupon.discount_value,
        'max_discount', v_coupon.max_discount
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.secure_create_order(
    p_items JSONB,
    p_delivery_mode TEXT,
    p_address TEXT,
    p_landmark TEXT,
    p_payment_method TEXT,
    p_coupon_code TEXT,
    p_use_wallet BOOLEAN,
    p_session_token TEXT
)
RETURNS JSONB AS $$
DECLARE
    v_session RECORD;
    v_user RECORD;
    v_item RECORD;
    v_subtotal NUMERIC := 0.0;
    v_item_price NUMERIC;
    v_item_total NUMERIC;
    v_addon_price NUMERIC;
    v_addon_id BIGINT;
    v_addon RECORD;
    v_delivery_fee NUMERIC := 0.0;
    v_delivery_settings RECORD;
    v_gst NUMERIC := 0.0;
    v_coupon_discount NUMERIC := 0.0;
    v_coupon_res JSONB;
    v_wallet RECORD;
    v_wallet_settings RECORD;
    v_wallet_redeem_coins INT := 0;
    v_wallet_redeem_rupees NUMERIC := 0.0;
    v_final_total NUMERIC := 0.0;
    v_order_id BIGINT;
    v_items_count INT;
    v_variant_name TEXT;
    v_addons_names TEXT;
    v_item_data JSONB;
    v_addon_data JSONB;
    v_order_item_id BIGINT;
BEGIN
    -- 1. Validate Session Token
    SELECT * INTO v_session 
    FROM public.active_sessions 
    WHERE token = p_session_token AND expires_at > NOW() 
    LIMIT 1;

    IF v_session IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Session expired or invalid. Please log in again.');
    END IF;

    SELECT * INTO v_user 
    FROM public.orders_users_view -- fallback to users view or table
    LIMIT 1;
    -- Secure user load
    SELECT * INTO v_user 
    FROM public.users 
    WHERE id = v_session.user_id 
    LIMIT 1;

    IF v_user IS NULL OR v_user.status <> 'active' THEN
        RETURN jsonb_build_object('success', false, 'error', 'User account is suspended or invalid.');
    END IF;

    -- 2. Calculate Subtotal and Verify Item Prices Server-Side
    v_items_count := jsonb_array_length(p_items);
    IF v_items_count = 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'Order cart is empty.');
    END IF;

    FOR i IN 0..(v_items_count - 1) LOOP
        v_item_data := p_items->i;
        
        -- Get product base price
        SELECT price INTO v_item_price 
        FROM public.products 
        WHERE id = (v_item_data->>'product_id')::BIGINT AND is_active = TRUE;

        IF v_item_price IS NULL THEN
            IF (v_item_data->>'isFreeGift')::BOOLEAN = TRUE THEN
                v_item_price := 0.0;
            ELSE
                RETURN jsonb_build_object('success', false, 'error', 'Product ' || (v_item_data->>'name') || ' is no longer available.');
            END IF;
        END IF;

        -- Verify variant price if specified
        v_variant_name := '';
        IF v_item_data->'variant' IS NOT NULL AND (v_item_data->'variant'->>'id') IS NOT NULL AND (v_item_data->'variant'->>'id') <> '' THEN
            v_variant_name := v_item_data->'variant'->>'name';
            SELECT price INTO v_item_price 
            FROM public.product_variants 
            WHERE id = (v_item_data->'variant'->>'id')::BIGINT;
            
            IF v_item_price IS NULL THEN
                RETURN jsonb_build_object('success', false, 'error', 'Product variant ' || v_variant_name || ' is invalid.');
            END IF;
        END IF;

        -- Verify Add-on prices
        v_addon_price := 0.0;
        IF v_item_data->'addons' IS NOT NULL AND jsonb_array_length(v_item_data->'addons') > 0 THEN
            FOR j IN 0..(jsonb_array_length(v_item_data->'addons') - 1) LOOP
                v_addon_data := v_item_data->'addons'->j;
                v_addon_id := (v_addon_data->>'id')::BIGINT;
                
                SELECT * INTO v_addon 
                FROM public.addons 
                WHERE id = v_addon_id;

                IF v_addon IS NOT NULL THEN
                    IF LOWER(v_variant_name) = 'small' AND v_addon.small_price IS NOT NULL THEN
                        v_addon_price := v_addon_price + v_addon.small_price;
                    ELSIF LOWER(v_variant_name) = 'medium' AND v_addon.medium_price IS NOT NULL THEN
                        v_addon_price := v_addon_price + v_addon.medium_price;
                    ELSE
                        v_addon_price := v_addon_price + COALESCE(v_addon.price, 0.0);
                    END IF;
                END IF;
            END LOOP;
        END IF;

        -- For meals, add upgrade charges to the base item price
        IF v_item_data->'meal_configurations' IS NOT NULL AND jsonb_array_length(v_item_data->'meal_configurations') > 0 THEN
            DECLARE
                v_meal_cfg JSONB;
                v_item_elem JSONB;
                v_upgrade_sum NUMERIC := 0.0;
                v_group_id BIGINT;
                v_rep_prod_id BIGINT;
                
                v_db_included_prod_id BIGINT;
                v_db_pricing_mode TEXT;
                
                v_default_price NUMERIC := 0.0;
                v_replacement_price NUMERIC := 0.0;
                v_calc_charge NUMERIC := 0.0;
                
                v_db_rep_variant_id BIGINT;
                v_price_override NUMERIC;
            BEGIN
                FOR j IN 0..(jsonb_array_length(v_item_data->'meal_configurations') - 1) LOOP
                    v_meal_cfg := v_item_data->'meal_configurations'->j;
                    v_group_id := (v_meal_cfg->>'group_id')::BIGINT;
                    
                    SELECT included_product_id, pricing_mode INTO v_db_included_prod_id, v_db_pricing_mode
                    FROM public.meal_groups
                    WHERE id = v_group_id;
                    
                    IF v_db_included_prod_id IS NOT NULL AND v_meal_cfg->'selected_items' IS NOT NULL THEN
                        FOR k IN 0..(jsonb_array_length(v_meal_cfg->'selected_items') - 1) LOOP
                            v_item_elem := v_meal_cfg->'selected_items'->k;
                            v_rep_prod_id := (v_item_elem->>'product_id')::BIGINT;
                            
                            IF v_db_pricing_mode IS NULL OR v_db_pricing_mode = '' THEN
                                v_db_pricing_mode := 'auto';
                            END IF;
                            
                            IF v_rep_prod_id = v_db_included_prod_id THEN
                                v_calc_charge := 0.0;
                            ELSIF v_db_pricing_mode = 'manual' THEN
                                SELECT price_override INTO v_price_override
                                FROM public.meal_group_items
                                WHERE group_id = v_group_id AND product_id = v_rep_prod_id;
                                
                                v_calc_charge := COALESCE(v_price_override, 0.0);
                            ELSE
                                -- Auto pricing
                                SELECT variant_id INTO v_db_rep_variant_id
                                FROM public.meal_group_items
                                WHERE group_id = v_group_id AND product_id = v_db_included_prod_id
                                LIMIT 1;
                                
                                IF v_db_rep_variant_id IS NOT NULL THEN
                                    SELECT price INTO v_default_price FROM public.product_variants WHERE id = v_db_rep_variant_id;
                                ELSE
                                    SELECT price INTO v_default_price FROM public.products WHERE id = v_db_included_prod_id;
                                END IF;
                                
                                SELECT variant_id INTO v_db_rep_variant_id
                                FROM public.meal_group_items
                                WHERE group_id = v_group_id AND product_id = v_rep_prod_id
                                LIMIT 1;
                                
                                IF v_db_rep_variant_id IS NOT NULL THEN
                                    SELECT price INTO v_replacement_price FROM public.product_variants WHERE id = v_db_rep_variant_id;
                                ELSE
                                    SELECT price INTO v_replacement_price FROM public.products WHERE id = v_rep_prod_id;
                                END IF;
                                
                                v_calc_charge := GREATEST(0.0, COALESCE(v_replacement_price, 0.0) - COALESCE(v_default_price, 0.0));
                            END IF;
                            
                            v_upgrade_sum := v_upgrade_sum + v_calc_charge;
                        END LOOP;
                    END IF;
                END LOOP;
                v_item_price := v_item_price + v_upgrade_sum;
            END;
        END IF;

        v_item_total := (v_item_price + v_addon_price) * (v_item_data->>'quantity')::INTEGER;
        v_subtotal := v_subtotal + v_item_total;
    END LOOP;

    -- 3. Load Delivery Settings and Compute Delivery Fee
    SELECT * INTO v_delivery_settings 
    FROM public.delivery_settings 
    LIMIT 1;

    IF p_delivery_mode IN ('delivery', 'schedule') THEN
        IF v_delivery_settings IS NOT NULL AND v_subtotal < v_delivery_settings.free_delivery_above THEN
            v_delivery_fee := v_delivery_settings.delivery_charge;
        END IF;
    END IF;

    -- 4. Calculate GST (5% standard)
    v_gst := ROUND(v_subtotal * 0.05, 2);

    -- 5. Validate and Calculate Coupon Discount
    IF p_coupon_code IS NOT NULL AND p_coupon_code <> '' THEN
        v_coupon_res := public.secure_validate_coupon(p_coupon_code, v_subtotal, v_user.id);
        
        IF (v_coupon_res->>'valid')::BOOLEAN = TRUE THEN
            IF v_coupon_res->>'discount_type' = 'percentage' THEN
                v_coupon_discount := ROUND(v_subtotal * ((v_coupon_res->>'discount_value')::NUMERIC / 100.0), 2);
                IF (v_coupon_res->>'max_discount') IS NOT NULL THEN
                    v_coupon_discount := LEAST(v_coupon_discount, (v_coupon_res->>'max_discount')::NUMERIC);
                END IF;
            ELSIF v_coupon_res->>'discount_type' = 'flat' THEN
                v_coupon_discount := LEAST((v_coupon_res->>'discount_value')::NUMERIC, v_subtotal);
            END IF;
        ELSE
            INSERT INTO public.security_events (user_id, event_type, severity, description)
            VALUES (v_user.id, 'coupon_abuse', 'medium', 'Failed attempt to apply coupon ' || p_coupon_code || '. Reason: ' || (v_coupon_res->>'error'));
        END IF;
    END IF;

    -- 6. Validate Wallet Redemption
    IF p_use_wallet = TRUE THEN
        SELECT * INTO v_wallet 
        FROM public.cheesy_wallets 
        WHERE user_id = v_user.id AND wallet_status = 'active';

        SELECT * INTO v_wallet_settings 
        FROM public.cheesy_wallet_settings 
        LIMIT 1;

        IF v_wallet IS NOT NULL AND v_wallet_settings IS NOT NULL AND v_wallet.available_coins > 0 THEN
            IF v_subtotal >= v_wallet_settings.min_order_value THEN
                DECLARE
                    v_max_rupee_discount NUMERIC;
                    v_coins_needed INT;
                BEGIN
                    v_max_rupee_discount := ROUND(v_subtotal * (v_wallet_settings.max_redeem_percent / 100.0), 2);
                    v_coins_needed := CEIL(v_max_rupee_discount * (v_wallet_settings.coin_ratio_coins / v_wallet_settings.coin_ratio_rupees));
                    
                    v_wallet_redeem_coins := LEAST(v_wallet.available_coins, v_coins_needed);
                    v_wallet_redeem_rupees := ROUND(v_wallet_redeem_coins * (v_wallet_settings.coin_ratio_rupees / v_wallet_settings.coin_ratio_coins), 2);
                END;
            END IF;
        END IF;
    END IF;

    -- 7. Calculate Final Total
    v_final_total := v_subtotal + v_gst + v_delivery_fee - v_coupon_discount - v_wallet_redeem_rupees;
    IF v_final_total < 0 THEN
        v_final_total := 0.0;
    END IF;

    -- 8. Insert Order Record securely
    INSERT INTO public.orders (
        user_id, customer_name, phone, address, landmark, 
        payment_method, payment_status, subtotal, gst, delivery_fee, 
        total, status, delivery_mode, coupon_code, coupon_discount, 
        coins_redeemed, coins_earned, order_source
    ) VALUES (
        v_user.id, v_user.full_name, v_user.mobile, p_address, p_landmark,
        p_payment_method, 'Paid', v_subtotal, v_gst, v_delivery_fee,
        v_final_total, 'Pending', p_delivery_mode, p_coupon_code, v_coupon_discount,
        v_wallet_redeem_coins, 0, 'online'
    ) RETURNING id INTO v_order_id;

    -- 9. Insert Order Items Records
    FOR i IN 0..(v_items_count - 1) LOOP
        v_item_data := p_items->i;
        v_item_price := (v_item_data->>'price')::NUMERIC;
        v_variant_name := COALESCE(v_item_data->'variant'->>'name', '');

        -- Format addons / meal configurations text
        v_addons_names := '';
        IF v_item_data->'meal_configurations' IS NOT NULL AND jsonb_array_length(v_item_data->'meal_configurations') > 0 THEN
            DECLARE
                v_meal_cfg JSONB;
                v_group_name TEXT;
                v_item_names TEXT := '';
                v_formatted_cfgs TEXT := '';
                v_group_id BIGINT;
                v_db_included_prod_id BIGINT;
                v_db_pricing_mode TEXT;
            BEGIN
                FOR j IN 0..(jsonb_array_length(v_item_data->'meal_configurations') - 1) LOOP
                    v_meal_cfg := v_item_data->'meal_configurations'->j;
                    v_group_name := v_meal_cfg->>'group_name';
                    v_group_id := (v_meal_cfg->>'group_id')::BIGINT;
                    v_item_names := '';
                    
                    SELECT included_product_id, pricing_mode INTO v_db_included_prod_id, v_db_pricing_mode
                    FROM public.meal_groups
                    WHERE id = v_group_id;
                    
                    IF v_meal_cfg->'selected_items' IS NOT NULL AND jsonb_array_length(v_meal_cfg->'selected_items') > 0 THEN
                        DECLARE
                            v_item_elem JSONB;
                            v_rep_prod_id BIGINT;
                            v_calc_charge NUMERIC;
                            v_default_price NUMERIC;
                            v_replacement_price NUMERIC;
                            v_db_rep_variant_id BIGINT;
                            v_price_override NUMERIC;
                            v_included_prod_name TEXT;
                            v_elem_val TEXT;
                            v_sub_items_list TEXT[] := ARRAY[]::TEXT[];
                        BEGIN
                            FOR k IN 0..(jsonb_array_length(v_meal_cfg->'selected_items') - 1) LOOP
                                v_item_elem := v_meal_cfg->'selected_items'->k;
                                v_rep_prod_id := (v_item_elem->>'product_id')::BIGINT;
                                
                                IF v_db_included_prod_id IS NOT NULL THEN
                                    IF v_db_pricing_mode IS NULL OR v_db_pricing_mode = '' THEN
                                        v_db_pricing_mode := 'auto';
                                    END IF;
                                    
                                    IF v_rep_prod_id = v_db_included_prod_id THEN
                                        v_calc_charge := 0.0;
                                    ELSIF v_db_pricing_mode = 'manual' THEN
                                        SELECT price_override INTO v_price_override
                                        FROM public.meal_group_items
                                        WHERE group_id = v_group_id AND product_id = v_rep_prod_id;
                                        
                                        v_calc_charge := COALESCE(v_price_override, 0.0);
                                    ELSE
                                        SELECT variant_id INTO v_db_rep_variant_id
                                        FROM public.meal_group_items
                                        WHERE group_id = v_group_id AND product_id = v_db_included_prod_id
                                        LIMIT 1;
                                        
                                        IF v_db_rep_variant_id IS NOT NULL THEN
                                            SELECT price INTO v_default_price FROM public.product_variants WHERE id = v_db_rep_variant_id;
                                        ELSE
                                            SELECT price INTO v_default_price FROM public.products WHERE id = v_db_included_prod_id;
                                        END IF;
                                        
                                        SELECT variant_id INTO v_db_rep_variant_id
                                        FROM public.meal_group_items
                                        WHERE group_id = v_group_id AND product_id = v_rep_prod_id;
                                        
                                        IF v_db_rep_variant_id IS NOT NULL THEN
                                            SELECT price INTO v_replacement_price FROM public.product_variants WHERE id = v_db_rep_variant_id;
                                        ELSE
                                            SELECT price INTO v_replacement_price FROM public.products WHERE id = v_rep_prod_id;
                                        END IF;
                                        
                                        v_calc_charge := GREATEST(0.0, COALESCE(v_replacement_price, 0.0) - COALESCE(v_default_price, 0.0));
                                    END IF;
                                    
                                    IF v_rep_prod_id = v_db_included_prod_id THEN
                                        v_elem_val := v_item_elem->>'name';
                                    ELSE
                                        SELECT name INTO v_included_prod_name FROM public.products WHERE id = v_db_included_prod_id;
                                        v_elem_val := COALESCE(v_included_prod_name, 'Included') || ' → ' || (v_item_elem->>'name');
                                        IF v_calc_charge > 0 THEN
                                            v_elem_val := v_elem_val || ' (+₹' || v_calc_charge || ')';
                                        END IF;
                                    END IF;
                                ELSE
                                    v_elem_val := v_item_elem->>'name';
                                END IF;
                                
                                v_sub_items_list := array_append(v_sub_items_list, v_elem_val);
                            END LOOP;
                            
                            SELECT string_agg(s, ', ') INTO v_item_names FROM unnest(v_sub_items_list) s;
                        END;
                    END IF;
                    
                    IF v_item_names <> '' THEN
                        IF v_formatted_cfgs <> '' THEN
                            v_formatted_cfgs := v_formatted_cfgs || '; ';
                        END IF;
                        v_formatted_cfgs := v_formatted_cfgs || v_group_name || ': [' || v_item_names || ']';
                    END IF;
                END LOOP;
                v_addons_names := v_formatted_cfgs;
            END;
        ELSIF v_item_data->'addons' IS NOT NULL AND jsonb_array_length(v_item_data->'addons') > 0 THEN
            SELECT string_agg(name, ', ') INTO v_addons_names 
            FROM public.addons 
            WHERE id IN (
                SELECT (jsonb_array_elements(v_item_data->'addons')->>'id')::BIGINT
            );
        END IF;

        INSERT INTO public.order_items (
            order_id, product_id, product_name, product_image, 
            variant_name, addons, quantity, price, total
        ) VALUES (
            v_order_id, 
            (v_item_data->>'product_id')::BIGINT,
            (v_item_data->>'name'),
            (v_item_data->>'image'),
            v_variant_name,
            COALESCE(v_addons_names, ''),
            (v_item_data->>'quantity')::INTEGER,
            v_item_price,
            v_item_price * (v_item_data->>'quantity')::INTEGER
        ) RETURNING id INTO v_order_item_id;

        -- Insert into public.order_meal_upgrades
        IF v_item_data->'meal_configurations' IS NOT NULL AND jsonb_array_length(v_item_data->'meal_configurations') > 0 THEN
            DECLARE
                v_meal_cfg JSONB;
                v_item_elem JSONB;
                v_group_id BIGINT;
                v_rep_prod_id BIGINT;
                
                v_db_included_prod_id BIGINT;
                v_db_pricing_mode TEXT;
                
                v_default_price NUMERIC := 0.0;
                v_replacement_price NUMERIC := 0.0;
                v_calc_charge NUMERIC := 0.0;
                
                v_db_rep_variant_id BIGINT;
                v_price_override NUMERIC;
            BEGIN
                FOR j IN 0..(jsonb_array_length(v_item_data->'meal_configurations') - 1) LOOP
                    v_meal_cfg := v_item_data->'meal_configurations'->j;
                    v_group_id := (v_meal_cfg->>'group_id')::BIGINT;
                    
                    SELECT included_product_id, pricing_mode INTO v_db_included_prod_id, v_db_pricing_mode
                    FROM public.meal_groups
                    WHERE id = v_group_id;
                    
                    IF v_db_included_prod_id IS NOT NULL AND v_meal_cfg->'selected_items' IS NOT NULL THEN
                        FOR k IN 0..(jsonb_array_length(v_meal_cfg->'selected_items') - 1) LOOP
                            v_item_elem := v_meal_cfg->'selected_items'->k;
                            v_rep_prod_id := (v_item_elem->>'product_id')::BIGINT;
                            
                            IF v_db_pricing_mode IS NULL OR v_db_pricing_mode = '' THEN
                                v_db_pricing_mode := 'auto';
                            END IF;
                            
                            IF v_rep_prod_id = v_db_included_prod_id THEN
                                v_calc_charge := 0.0;
                            ELSIF v_db_pricing_mode = 'manual' THEN
                                SELECT price_override INTO v_price_override
                                FROM public.meal_group_items
                                WHERE group_id = v_group_id AND product_id = v_rep_prod_id;
                                
                                v_calc_charge := COALESCE(v_price_override, 0.0);
                            ELSE
                                SELECT variant_id INTO v_db_rep_variant_id
                                FROM public.meal_group_items
                                WHERE group_id = v_group_id AND product_id = v_db_included_prod_id
                                LIMIT 1;
                                
                                IF v_db_rep_variant_id IS NOT NULL THEN
                                    SELECT price INTO v_default_price FROM public.product_variants WHERE id = v_db_rep_variant_id;
                                ELSE
                                    SELECT price INTO v_default_price FROM public.products WHERE id = v_db_included_prod_id;
                                END IF;
                                
                                SELECT variant_id INTO v_db_rep_variant_id
                                FROM public.meal_group_items
                                WHERE group_id = v_group_id AND product_id = v_rep_prod_id;
                                
                                IF v_db_rep_variant_id IS NOT NULL THEN
                                    SELECT price INTO v_replacement_price FROM public.product_variants WHERE id = v_db_rep_variant_id;
                                ELSE
                                    SELECT price INTO v_replacement_price FROM public.products WHERE id = v_rep_prod_id;
                                END IF;
                                
                                v_calc_charge := GREATEST(0.0, COALESCE(v_replacement_price, 0.0) - COALESCE(v_default_price, 0.0));
                            END IF;
                            
                            IF v_rep_prod_id <> v_db_included_prod_id THEN
                                INSERT INTO public.order_meal_upgrades (
                                    order_item_id, group_id, included_product_id, 
                                    upgrade_product_id, pricing_mode, upgrade_charge
                                ) VALUES (
                                    v_order_item_id, v_group_id, v_db_included_prod_id, 
                                    v_rep_prod_id, v_db_pricing_mode, v_calc_charge
                                );
                            END IF;
                        END LOOP;
                    END IF;
                END LOOP;
            END;
        END IF;
    END LOOP;

    -- 10. Record Coupon Usage
    IF v_coupon_discount > 0 AND p_coupon_code IS NOT NULL THEN
        DECLARE
            v_coupon_id BIGINT;
        BEGIN
            SELECT id INTO v_coupon_id FROM public.coupons WHERE code = p_coupon_code LIMIT 1;
            IF v_coupon_id IS NOT NULL THEN
                INSERT INTO public.coupon_usage (coupon_id, user_id, order_id)
                VALUES (v_coupon_id, v_user.id, v_order_id);
            END IF;
        END;
    END IF;

    -- 11. Process Wallet coins deduction
    IF v_wallet_redeem_coins > 0 THEN
        UPDATE public.cheesy_wallets 
        SET available_coins = available_coins - v_wallet_redeem_coins,
            lifetime_redeemed = lifetime_redeemed + v_wallet_redeem_coins,
            updated_at = NOW()
        WHERE user_id = v_user.id;

        INSERT INTO public.cheesy_wallet_transactions (
            user_id, transaction_type, coins, rupee_value, 
            reference_type, reference_id, remarks
        ) VALUES (
            v_user.id, 'redeem', v_wallet_redeem_coins, v_wallet_redeem_rupees,
            'order', v_order_id::text, 'Redeemed on order #' || v_order_id
        );
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'order_id', v_order_id,
        'total', v_final_total,
        'subtotal', v_subtotal,
        'gst', v_gst,
        'delivery_fee', v_delivery_fee,
        'coupon_discount', v_coupon_discount,
        'wallet_discount', v_wallet_redeem_rupees
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.secure_staff_check_in(
    p_lat NUMERIC,
    p_lng NUMERIC,
    p_photo_url TEXT,
    p_checklist JSONB,
    p_session_token TEXT
)
RETURNS JSONB AS $$
DECLARE
    v_session RECORD;
    v_user RECORD;
    v_settings RECORD;
    v_today DATE := CURRENT_DATE;
    v_attendance_id BIGINT;
    v_checklist_id BIGINT;
    v_distance NUMERIC;
    v_status TEXT := 'Present';
    v_reason TEXT := '';
    v_login_time TIMESTAMPTZ := NOW();
BEGIN
    -- Resolve User
    SELECT * INTO v_session 
    FROM public.active_sessions 
    WHERE token = p_session_token AND expires_at > NOW() 
    LIMIT 1;

    IF v_session IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Authentication failed');
    END IF;

    SELECT * INTO v_user 
    FROM public.users 
    WHERE id = v_session.user_id 
    LIMIT 1;

    -- Load Attendance Settings
    SELECT * INTO v_settings FROM public.attendance_settings WHERE id = 1 LIMIT 1;

    -- GPS Distance Verification
    IF v_settings IS NOT NULL THEN
        -- Approximate distance in meters
        v_distance := 111319.9 * DEGREES(ACOS(
            LEAST(1.0, COS(RADIANS(p_lat)) * COS(RADIANS(v_settings.gps_lat)) * COS(RADIANS(v_settings.gps_lng - p_lng)) + 
            SIN(RADIANS(p_lat)) * SIN(RADIANS(v_settings.gps_lat)))
        ));

        IF v_distance > v_settings.gps_radius_meters THEN
            -- Flag as out-of-bounds but record with warning
            v_reason := 'Checked in out of bounds: ' || ROUND(v_distance) || 'm from branch';
            INSERT INTO public.security_events (user_id, event_type, severity, description)
            VALUES (v_user.id, 'attendance_abuse', 'medium', 'Staff checked in out of range: ' || ROUND(v_distance) || 'm');
        END IF;
    END IF;

    -- Check if opening checklist is already completed today
    SELECT id INTO v_checklist_id 
    FROM public.opening_checklists 
    WHERE staff_id = v_user.id AND date = v_today 
    LIMIT 1;

    IF v_checklist_id IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Already checked in today');
    END IF;

    -- Look up existing attendance record for today (created during Login)
    SELECT id INTO v_attendance_id 
    FROM public.staff_attendance 
    WHERE staff_id = v_user.id AND date = v_today 
    LIMIT 1;

    IF v_attendance_id IS NOT NULL THEN
        -- Update existing attendance record with checklist completion details
        UPDATE public.staff_attendance 
        SET opening_checklist_completed = TRUE,
            opening_photo_uploaded = (p_photo_url IS NOT NULL AND p_photo_url <> ''),
            opening_completed_at = v_login_time,
            status_reason = CASE 
                WHEN status_reason IS NULL OR status_reason = '' THEN v_reason 
                ELSE status_reason || '; ' || v_reason 
            END
        WHERE id = v_attendance_id;
    ELSE
        -- Insert Attendance Record if not exists
        INSERT INTO public.staff_attendance (
            staff_id, staff_name, date, login_time, status, login_gps, 
            login_device, opening_checklist_completed, opening_photo_uploaded, 
            opening_completed_at, status_reason
        ) VALUES (
            v_user.id, v_user.full_name, v_today, v_login_time, v_status,
            p_lat::text || ',' || p_lng::text, v_session.device, TRUE,
            p_photo_url IS NOT NULL AND p_photo_url <> '', v_login_time, v_reason
        ) RETURNING id INTO v_attendance_id;
    END IF;

    -- Insert Checklist entry to public.opening_checklists
    INSERT INTO public.opening_checklists (
        staff_id, staff_name, date,
        hair_cap, hands_washed, nails_clean, uniform_worn,
        milk_opening_stock, cheese_opening_stock,
        vegetables_cleaned, vegetable_cleaning_photo, kitchen_opening_photo,
        staff_selfie_photo,
        created_at
    ) VALUES (
        v_user.id, v_user.full_name, v_today,
        COALESCE((p_checklist->>'hair_cap')::BOOLEAN, false),
        COALESCE((p_checklist->>'hands_washed')::BOOLEAN, false),
        COALESCE((p_checklist->>'nails_clean')::BOOLEAN, false),
        COALESCE((p_checklist->>'uniform_worn')::BOOLEAN, false),
        COALESCE((p_checklist->>'milk_opening_stock')::NUMERIC, 0.0),
        COALESCE((p_checklist->>'cheese_opening_stock')::NUMERIC, 0.0),
        COALESCE((p_checklist->>'vegetables_cleaned')::BOOLEAN, false),
        COALESCE(p_checklist->>'vegetable_cleaning_photo', ''),
        COALESCE(p_checklist->>'kitchen_opening_photo', ''),
        COALESCE(p_checklist->>'staff_selfie_photo', ''),
        v_login_time
    ) ON CONFLICT (staff_id, date) DO UPDATE 
    SET hair_cap = EXCLUDED.hair_cap,
        hands_washed = EXCLUDED.hands_washed,
        nails_clean = EXCLUDED.nails_clean,
        uniform_worn = EXCLUDED.uniform_worn,
        milk_opening_stock = EXCLUDED.milk_opening_stock,
        cheese_opening_stock = EXCLUDED.cheese_opening_stock,
        vegetables_cleaned = EXCLUDED.vegetables_cleaned,
        vegetable_cleaning_photo = EXCLUDED.vegetable_cleaning_photo,
        kitchen_opening_photo = EXCLUDED.kitchen_opening_photo,
        staff_selfie_photo = EXCLUDED.staff_selfie_photo,
        created_at = EXCLUDED.created_at;

    RETURN jsonb_build_object('success', true, 'attendance_id', v_attendance_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.secure_staff_check_out(
    p_lat NUMERIC,
    p_lng NUMERIC,
    p_photo_url TEXT,
    p_checklist JSONB,
    p_session_token TEXT
)
RETURNS JSONB AS $$
DECLARE
    v_session RECORD;
    v_user RECORD;
    v_today DATE := CURRENT_DATE;
    v_attendance RECORD;
    v_logout_time TIMESTAMPTZ := NOW();
    v_working_hours NUMERIC;
    v_compliance_score NUMERIC := 0.0;
    v_opening_checklist_comp BOOLEAN;
    v_opening_photo_comp BOOLEAN;
    v_tasks_completed_count INT := 0;
    v_tasks_total_count INT := 0;
    v_tasks_score NUMERIC := 0.0;
    v_status TEXT := 'Present';
BEGIN
    -- Resolve User
    SELECT * INTO v_session 
    FROM public.active_sessions 
    WHERE token = p_session_token AND expires_at > NOW() 
    LIMIT 1;

    IF v_session IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Authentication failed');
    END IF;

    SELECT * INTO v_user 
    FROM public.users 
    WHERE id = v_session.user_id 
    LIMIT 1;

    -- Lookup today's checkin
    SELECT * INTO v_attendance 
    FROM public.staff_attendance 
    WHERE staff_id = v_user.id AND date = v_today 
    LIMIT 1;

    IF v_attendance IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'No check-in record found for today');
    END IF;

    -- Calculate Working Hours
    v_working_hours := ROUND(EXTRACT(EPOCH FROM (v_logout_time - v_attendance.login_time)) / 3600.0, 2);

    -- Calculate Checklist Compliance Score
    -- Opening Checklist = 20%
    v_opening_checklist_comp := COALESCE(v_attendance.opening_checklist_completed, false);
    IF v_opening_checklist_comp THEN
        v_compliance_score := v_compliance_score + 20.0;
    END IF;

    -- Opening Photo = 10%
    v_opening_photo_comp := COALESCE(v_attendance.opening_photo_uploaded, false);
    IF v_opening_photo_comp THEN
        v_compliance_score := v_compliance_score + 10.0;
    END IF;

    -- Stocks checklist completed (Stock entries) = 15%
    v_compliance_score := v_compliance_score + 15.0;

    -- Tasks completion = 30%
    BEGIN
        SELECT COUNT(*) INTO v_tasks_total_count 
        FROM public.staff_tasks;
        
        IF v_tasks_total_count = 0 THEN
            v_compliance_score := v_compliance_score + 30.0;
        ELSE
            v_compliance_score := v_compliance_score + 30.0;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            v_compliance_score := v_compliance_score + 30.0;
    END;

    -- Closing Checklist = 15%
    v_compliance_score := v_compliance_score + 15.0;

    -- Closing Photo = 10%
    IF p_photo_url IS NOT NULL AND p_photo_url <> '' THEN
        v_compliance_score := v_compliance_score + 10.0;
    END IF;

    -- Enforce Attendance status based on Compliance score
    IF v_compliance_score >= 80.0 THEN
        v_status := 'Present';
    ELSIF v_compliance_score >= 41.0 THEN
        v_status := 'Half Day';
    ELSE
        v_status := 'Absent';
    END IF;

    -- Update Attendance Record
    UPDATE public.staff_attendance 
    SET logout_time = v_logout_time,
        working_hours = v_working_hours,
        net_working_hours = v_working_hours,
        status = v_status,
        logout_gps = p_lat::text || ',' || p_lng::text,
        logout_device = v_session.device,
        closing_checklist_completed = TRUE,
        closing_photos_uploaded = (p_photo_url IS NOT NULL AND p_photo_url <> ''),
        closing_completed_at = v_logout_time
    WHERE id = v_attendance.id;

    -- Insert Closing Checklist record
    INSERT INTO public.closing_checklists (
        staff_id, staff_name, date,
        milk_closing_stock, cheese_closing_stock,
        deep_cleaning_completed, kitchen_closing_photo, counter_closing_photo,
        remarks, created_at
    ) VALUES (
        v_user.id, v_user.full_name, v_today,
        COALESCE((p_checklist->>'milk_closing_stock')::NUMERIC, 0.0),
        COALESCE((p_checklist->>'cheese_closing_stock')::NUMERIC, 0.0),
        COALESCE((p_checklist->>'deep_cleaning_completed')::BOOLEAN, false),
        COALESCE(p_checklist->>'kitchen_closing_photo', ''),
        COALESCE(p_checklist->>'counter_closing_photo', ''),
        COALESCE(p_checklist->>'remarks', ''),
        v_logout_time
    ) ON CONFLICT (staff_id, date) DO UPDATE 
    SET milk_closing_stock = EXCLUDED.milk_closing_stock,
        cheese_closing_stock = EXCLUDED.cheese_closing_stock,
        deep_cleaning_completed = EXCLUDED.deep_cleaning_completed,
        kitchen_closing_photo = EXCLUDED.kitchen_closing_photo,
        counter_closing_photo = EXCLUDED.counter_closing_photo,
        remarks = EXCLUDED.remarks,
        created_at = EXCLUDED.created_at;

    RETURN jsonb_build_object(
        'success', true, 
        'working_hours', v_working_hours,
        'compliance_score', v_compliance_score,
        'status', v_status
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.secure_adjust_inventory(
    p_product_id BIGINT,
    p_adjustment_qty INTEGER,
    p_reason TEXT,
    p_session_token TEXT
)
RETURNS JSONB AS $$
DECLARE
    v_session RECORD;
    v_user RECORD;
    v_current_stock BOOLEAN;
    v_product_name TEXT;
BEGIN
    -- Verify User Session and role
    SELECT * INTO v_session 
    FROM public.active_sessions 
    WHERE token = p_session_token AND expires_at > NOW() 
    LIMIT 1;

    IF v_session IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Session expired or invalid.');
    END IF;

    SELECT * INTO v_user 
    FROM public.users 
    WHERE id = v_session.user_id 
    LIMIT 1;

    IF v_user IS NULL OR v_user.role NOT IN ('super_admin', 'admin', 'manager', 'staff_admin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'Unauthorized. Only admins or managers can adjust stock.');
    END IF;

    -- Verify product
    SELECT name, stock INTO v_product_name, v_current_stock 
    FROM public.products 
    WHERE id = p_product_id;

    IF v_product_name IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Product not found.');
    END IF;

    -- Update stock status (since stock is BOOLEAN on products table, toggle or update)
    IF p_adjustment_qty <= 0 THEN
        UPDATE public.products SET stock = FALSE WHERE id = p_product_id;
    ELSE
        UPDATE public.products SET stock = TRUE WHERE id = p_product_id;
    END IF;

    -- Log to System Audit Logs
    INSERT INTO public.system_audit_logs (
        user_name, user_role, action, device, details
    ) VALUES (
        v_user.full_name, v_user.role, 'adjust_inventory', v_session.device,
        jsonb_build_object(
            'product_id', p_product_id,
            'product_name', v_product_name,
            'adjustment_qty', p_adjustment_qty,
            'reason', p_reason
        )
    );

    RETURN jsonb_build_object('success', true, 'message', 'Stock adjusted successfully.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.secure_terminate_session(
    p_session_token TEXT,
    p_target_session_id BIGINT
)
RETURNS JSONB AS $$
DECLARE
    v_session RECORD;
    v_user RECORD;
    v_target RECORD;
BEGIN
    -- Resolve checking user session
    SELECT * INTO v_session 
    FROM public.active_sessions 
    WHERE token = p_session_token AND expires_at > NOW() 
    LIMIT 1;

    IF v_session IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid session');
    END IF;

    SELECT * INTO v_user 
    FROM public.users 
    WHERE id = v_session.user_id 
    LIMIT 1;

    -- Only super_admin or admin can terminate session
    IF v_user IS NULL OR v_user.role NOT IN ('super_admin', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'Unauthorized');
    END IF;

    SELECT * INTO v_target 
    FROM public.active_sessions 
    WHERE id = p_target_session_id 
    LIMIT 1;

    IF v_target IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Target session not found');
    END IF;

    DELETE FROM public.active_sessions WHERE id = p_target_session_id;

    -- Log action
    INSERT INTO public.security_events (user_id, event_type, severity, description)
    VALUES (v_user.id, 'session_terminated', 'medium', 'Terminated session ID ' || p_target_session_id || ' for user ID ' || v_target.user_id);

    RETURN jsonb_build_object('success', true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.secure_terminate_user_sessions(
    p_session_token TEXT,
    p_target_user_id BIGINT
)
RETURNS JSONB AS $$
DECLARE
    v_session RECORD;
    v_user RECORD;
    v_target_user RECORD;
BEGIN
    -- Resolve checking user session
    SELECT * INTO v_session 
    FROM public.active_sessions 
    WHERE token = p_session_token AND expires_at > NOW() 
    LIMIT 1;

    IF v_session IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid session');
    END IF;

    SELECT * INTO v_user 
    FROM public.users 
    WHERE id = v_session.user_id 
    LIMIT 1;

    -- Only super_admin or admin can terminate sessions
    IF v_user IS NULL OR v_user.role NOT IN ('super_admin', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'Unauthorized');
    END IF;

    SELECT * INTO v_target_user 
    FROM public.users 
    WHERE id = p_target_user_id 
    LIMIT 1;

    IF v_target_user IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Target user not found');
    END IF;

    DELETE FROM public.active_sessions WHERE user_id = p_target_user_id;

    -- Log action
    INSERT INTO public.security_events (user_id, event_type, severity, description)
    VALUES (v_user.id, 'user_sessions_terminated', 'medium', 'Terminated all active sessions for user ' || v_target_user.full_name);

    RETURN jsonb_build_object('success', true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.secure_terminate_all_sessions(
    p_session_token TEXT
)
RETURNS JSONB AS $$
DECLARE
    v_session RECORD;
    v_user RECORD;
BEGIN
    -- Resolve checking user session
    SELECT * INTO v_session 
    FROM public.active_sessions 
    WHERE token = p_session_token AND expires_at > NOW() 
    LIMIT 1;

    IF v_session IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid session');
    END IF;

    SELECT * INTO v_user 
    FROM public.users 
    WHERE id = v_session.user_id 
    LIMIT 1;

    -- Only super_admin can terminate all sessions
    IF v_user IS NULL OR v_user.role <> 'super_admin' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Unauthorized');
    END IF;

    DELETE FROM public.active_sessions WHERE token <> p_session_token;

    -- Log action
    INSERT INTO public.security_events (user_id, event_type, severity, description)
    VALUES (v_user.id, 'all_sessions_terminated', 'high', 'Terminated all active sessions on system except their own.');

    RETURN jsonb_build_object('success', true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.secure_resolve_alert(
    p_session_token TEXT,
    p_alert_id BIGINT
)
RETURNS JSONB AS $$
DECLARE
    v_session RECORD;
    v_user RECORD;
    v_alert RECORD;
BEGIN
    SELECT * INTO v_session 
    FROM public.active_sessions 
    WHERE token = p_session_token AND expires_at > NOW() 
    LIMIT 1;

    IF v_session IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid session');
    END IF;

    SELECT * INTO v_user 
    FROM public.users 
    WHERE id = v_session.user_id 
    LIMIT 1;

    IF v_user IS NULL OR v_user.role NOT IN ('super_admin', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'Unauthorized');
    END IF;

    SELECT * INTO v_alert 
    FROM public.security_alerts 
    WHERE id = p_alert_id 
    LIMIT 1;

    IF v_alert IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Alert not found');
    END IF;

    UPDATE public.security_alerts 
    SET resolved = TRUE 
    WHERE id = p_alert_id;

    -- Log action
    INSERT INTO public.security_events (user_id, event_type, severity, description)
    VALUES (v_user.id, 'alert_resolved', 'low', 'Resolved security alert: ' || v_alert.description);

    RETURN jsonb_build_object('success', true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.secure_toggle_user_status(
    p_session_token TEXT,
    p_target_user_id BIGINT,
    p_status TEXT -- 'active' or 'suspended'
)
RETURNS JSONB AS $$
DECLARE
    v_session RECORD;
    v_user RECORD;
    v_target_user RECORD;
BEGIN
    SELECT * INTO v_session 
    FROM public.active_sessions 
    WHERE token = p_session_token AND expires_at > NOW() 
    LIMIT 1;

    IF v_session IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid session');
    END IF;

    SELECT * INTO v_user 
    FROM public.users 
    WHERE id = v_session.user_id 
    LIMIT 1;

    IF v_user IS NULL OR v_user.role NOT IN ('super_admin', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'Unauthorized');
    END IF;

    -- Verify target user
    SELECT * INTO v_target_user 
    FROM public.users 
    WHERE id = p_target_user_id 
    LIMIT 1;

    IF v_target_user IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Target user not found');
    END IF;

    IF v_target_user.role = 'super_admin' AND v_user.role <> 'super_admin' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Cannot suspend Super Admin accounts');
    END IF;

    UPDATE public.users 
    SET status = p_status, updated_at = NOW() 
    WHERE id = p_target_user_id;

    -- Log event
    INSERT INTO public.security_events (user_id, event_type, severity, description)
    VALUES (v_user.id, 'user_status_changed', 'medium', 'Changed status of user ' || v_target_user.full_name || ' to ' || p_status);

    -- If status is suspended, delete all sessions for that user
    IF p_status = 'suspended' THEN
        DELETE FROM public.active_sessions WHERE user_id = p_target_user_id;
    END IF;

    RETURN jsonb_build_object('success', true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.secure_assign_user_role(
    p_session_token TEXT,
    p_target_user_id BIGINT,
    p_role TEXT
)
RETURNS JSONB AS $$
DECLARE
    v_session RECORD;
    v_user RECORD;
    v_target_user RECORD;
BEGIN
    SELECT * INTO v_session 
    FROM public.active_sessions 
    WHERE token = p_session_token AND expires_at > NOW() 
    LIMIT 1;

    IF v_session IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid session');
    END IF;

    SELECT * INTO v_user 
    FROM public.users 
    WHERE id = v_session.user_id 
    LIMIT 1;

    -- Only super_admin or admin can assign roles
    IF v_user IS NULL OR v_user.role NOT IN ('super_admin', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'Unauthorized');
    END IF;

    -- Verify target user
    SELECT * INTO v_target_user 
    FROM public.users 
    WHERE id = p_target_user_id 
    LIMIT 1;

    IF v_target_user IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Target user not found');
    END IF;

    -- Prevent modifying super_admin role unless requester is super_admin
    IF v_target_user.role = 'super_admin' AND v_user.role <> 'super_admin' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Cannot modify Super Admin accounts');
    END IF;

    -- Update role
    UPDATE public.users 
    SET role = p_role, updated_at = NOW() 
    WHERE id = p_target_user_id;

    -- Log event
    INSERT INTO public.security_events (user_id, event_type, severity, description)
    VALUES (v_user.id, 'role_changed', 'medium', 'Changed role of user ' || v_target_user.full_name || ' to ' || p_role);

    RETURN jsonb_build_object('success', true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.secure_create_internal_user(
    p_session_token TEXT,
    p_full_name TEXT,
    p_mobile TEXT,
    p_email TEXT,
    p_password TEXT,
    p_role TEXT,
    p_branch_id BIGINT
)
RETURNS JSONB AS $$
DECLARE
    v_session RECORD;
    v_user RECORD;
    v_existing_user RECORD;
    v_emp_code TEXT;
    v_new_id BIGINT;
    v_next_id_str TEXT;
    v_existing_id_str TEXT;
BEGIN
    SELECT * INTO v_session 
    FROM public.active_sessions 
    WHERE token = p_session_token AND expires_at > NOW() 
    LIMIT 1;

    IF v_session IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid session');
    END IF;

    SELECT * INTO v_user 
    FROM public.users 
    WHERE id = v_session.user_id 
    LIMIT 1;

    -- Only super_admin or admin can create internal users
    IF v_user IS NULL OR v_user.role NOT IN ('super_admin', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'Unauthorized');
    END IF;

    -- Check if email already exists for another non-customer user
    IF p_email IS NOT NULL AND p_email <> '' AND EXISTS (
        SELECT 1 FROM public.users 
        WHERE email = p_email AND role <> 'customer' AND mobile <> p_mobile
    ) THEN
        RETURN jsonb_build_object('success', false, 'error', 'A user with this email already exists');
    END IF;

    -- Check if mobile already exists (either mobile or phone column)
    SELECT * INTO v_existing_user FROM public.users WHERE mobile = p_mobile OR phone = p_mobile LIMIT 1;

    IF v_existing_user IS NOT NULL THEN
        IF v_existing_user.role <> 'customer' THEN
            RETURN jsonb_build_object('success', false, 'error', 'A user with this mobile number already exists');
        END IF;

        -- If existing user is a customer, upgrade them to the internal role!
        v_existing_id_str := v_existing_user.id::text;
        v_emp_code := 'CB' || UPPER(SUBSTR(p_role, 1, 3)) || LPAD(v_existing_id_str, GREATEST(4, LENGTH(v_existing_id_str)), '0');

        UPDATE public.users
        SET full_name = p_full_name,
            name = p_full_name,
            mobile = p_mobile,
            phone = p_mobile,
            email = NULLIF(p_email, ''),
            password_hash = extensions.crypt(p_password, extensions.gen_salt('bf')),
            role = p_role,
            branch_id = p_branch_id,
            status = 'active',
            employee_code = v_emp_code,
            updated_at = NOW()
        WHERE id = v_existing_user.id;

        -- Log event
        INSERT INTO public.security_events (user_id, event_type, severity, description)
        VALUES (v_user.id, 'user_upgraded', 'low', 'Upgraded customer to internal user: ' || p_full_name || ' with role ' || p_role);

        RETURN jsonb_build_object('success', true, 'user_id', v_existing_user.id, 'employee_code', v_emp_code);
    ELSE
        -- Generate employee code
        v_next_id_str := ((SELECT COALESCE(MAX(id), 0) + 1 FROM public.users))::text;
        v_emp_code := 'CB' || UPPER(SUBSTR(p_role, 1, 3)) || LPAD(v_next_id_str, GREATEST(4, LENGTH(v_next_id_str)), '0');

        -- Insert new internal user
        INSERT INTO public.users (full_name, mobile, email, password_hash, role, branch_id, status, employee_code, created_by)
        VALUES (p_full_name, p_mobile, NULLIF(p_email, ''), extensions.crypt(p_password, extensions.gen_salt('bf')), p_role, p_branch_id, 'active', v_emp_code, v_user.id)
        RETURNING id INTO v_new_id;

        -- Log event
        INSERT INTO public.security_events (user_id, event_type, severity, description)
        VALUES (v_user.id, 'user_created', 'low', 'Created new internal user: ' || p_full_name || ' with role ' || p_role);

        RETURN jsonb_build_object('success', true, 'user_id', v_new_id, 'employee_code', v_emp_code);
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.secure_get_security_report(
    p_session_token TEXT
)
RETURNS JSONB AS $$
DECLARE
    v_session RECORD;
    v_user RECORD;
    v_score INT := 100;
    v_failed_logins_count INT;
    v_active_alerts_count INT;
    v_inactive_rls_count INT := 0;
    v_rls_report JSONB;
    v_sessions_count INT;
    v_users_count INT;
BEGIN
    -- Resolve checking user session
    SELECT * INTO v_session 
    FROM public.active_sessions 
    WHERE token = p_session_token AND expires_at > NOW() 
    LIMIT 1;

    IF v_session IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid session');
    END IF;

    SELECT * INTO v_user 
    FROM public.users 
    WHERE id = v_session.user_id 
    LIMIT 1;

    -- Only super_admin or admin
    IF v_user IS NULL OR v_user.role NOT IN ('super_admin', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'Unauthorized');
    END IF;

    -- Calculate metrics
    SELECT COUNT(*) INTO v_failed_logins_count FROM public.security_events WHERE event_type = 'failed_login';
    SELECT COUNT(*) INTO v_active_alerts_count FROM public.security_alerts WHERE resolved = FALSE;
    SELECT COUNT(*) INTO v_sessions_count FROM public.active_sessions WHERE expires_at > NOW();
    SELECT COUNT(*) INTO v_users_count FROM public.users;

    -- Build table RLS status list.
    DECLARE
        v_table_record RECORD;
        v_list JSONB := jsonb_build_array();
        v_enabled BOOLEAN;
        v_policy_count INT;
    BEGIN
        FOR v_table_record IN 
            SELECT tablename 
            FROM pg_tables 
            WHERE schemaname = 'public' 
              AND tablename IN ('users', 'orders', 'pos_orders', 'cheesy_wallets', 'cheesy_wallet_transactions', 'cheesy_wallet_settings', 'coupons', 'coupon_usage', 'active_sessions', 'security_events', 'security_alerts', 'staff_attendance', 'products', 'categories', 'addons', 'branches', 'roles', 'permissions', 'role_permissions', 'user_permissions')
        LOOP
            SELECT relrowsecurity INTO v_enabled 
            FROM pg_class 
            WHERE relname = v_table_record.tablename 
              AND relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public');

            SELECT COUNT(*) INTO v_policy_count 
            FROM pg_policies 
            WHERE schemaname = 'public' AND tablename = v_table_record.tablename;

            IF v_enabled = FALSE THEN
                v_inactive_rls_count := v_inactive_rls_count + 1;
            END IF;

            v_list := v_list || jsonb_build_object(
                'table_name', v_table_record.tablename,
                'rls_enabled', COALESCE(v_enabled, false),
                'policies_count', v_policy_count
            );
        END LOOP;
        v_rls_report := v_list;
    END;

    -- Adjust security score based on metrics
    v_score := v_score - (v_inactive_rls_count * 15);
    v_score := v_score - (v_active_alerts_count * 5);
    IF v_score < 0 THEN
        v_score := 0;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'security_score', v_score,
        'failed_logins', v_failed_logins_count,
        'active_alerts', v_active_alerts_count,
        'active_sessions_count', v_sessions_count,
        'total_users_count', v_users_count,
        'rls_tables', v_rls_report
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.secure_reset_user_credentials(
    p_session_token TEXT,
    p_target_user_id BIGINT,
    p_new_email TEXT,
    p_new_mobile TEXT,
    p_new_password TEXT
)
RETURNS JSONB AS $$
DECLARE
    v_session RECORD;
    v_user RECORD;
    v_target_user RECORD;
BEGIN
    -- Resolve checking user session
    SELECT * INTO v_session 
    FROM public.active_sessions 
    WHERE token = p_session_token AND expires_at > NOW() 
    LIMIT 1;

    IF v_session IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid session');
    END IF;

    SELECT * INTO v_user 
    FROM public.users 
    WHERE id = v_session.user_id 
    LIMIT 1;

    -- Only super_admin or admin can reset credentials
    IF v_user IS NULL OR v_user.role NOT IN ('super_admin', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'Unauthorized');
    END IF;

    -- Verify target user
    SELECT * INTO v_target_user 
    FROM public.users 
    WHERE id = p_target_user_id 
    LIMIT 1;

    IF v_target_user IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Target user not found');
    END IF;

    -- Protect super_admin: non-super-admins cannot reset super_admin credentials
    IF v_target_user.role = 'super_admin' AND v_user.role <> 'super_admin' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Cannot reset Super Admin credentials');
    END IF;

    -- Validate email uniqueness if changed
    IF p_new_email IS NOT NULL AND p_new_email <> '' AND p_new_email <> COALESCE(v_target_user.email, '') THEN
        IF EXISTS (SELECT 1 FROM public.users WHERE email = p_new_email) THEN
            RETURN jsonb_build_object('success', false, 'error', 'A user with this email already exists');
        END IF;
    END IF;

    -- Validate mobile uniqueness if changed
    IF p_new_mobile IS NOT NULL AND p_new_mobile <> '' AND p_new_mobile <> COALESCE(v_target_user.mobile, '') THEN
        IF EXISTS (SELECT 1 FROM public.users WHERE mobile = p_new_mobile OR phone = p_new_mobile) THEN
            RETURN jsonb_build_object('success', false, 'error', 'A user with this mobile number already exists');
        END IF;
    END IF;

    -- Update target user details
    UPDATE public.users 
    SET email = NULLIF(p_new_email, ''),
        mobile = p_new_mobile,
        password_hash = CASE WHEN p_new_password IS NOT NULL AND p_new_password <> '' THEN extensions.crypt(p_new_password, extensions.gen_salt('bf')) ELSE password_hash END,
        updated_at = NOW()
    WHERE id = p_target_user_id;

    -- If password is changed, force logout all device sessions for that user
    IF p_new_password IS NOT NULL AND p_new_password <> '' THEN
        DELETE FROM public.active_sessions WHERE user_id = p_target_user_id;
    END IF;

    -- Log action in security events audit trail
    INSERT INTO public.security_events (user_id, event_type, severity, description)
    VALUES (v_user.id, 'credentials_reset', 'medium', 'Reset credentials/password for user ' || v_target_user.full_name || ' (ID: ' || p_target_user_id || ')');

    RETURN jsonb_build_object('success', true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.block_direct_writes()
RETURNS TRIGGER AS $$
BEGIN
    IF current_user IN ('anon', 'authenticated') THEN
        RAISE EXCEPTION 'Direct client-side writes to this table are blocked for security compliance. Please perform all operations via RPC.';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.log_attendance_out_of_bounds_alert()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status_reason LIKE 'Checked in out of bounds%' THEN
        INSERT INTO public.security_alerts (user_id, alert_type, description, resolved)
        VALUES (NEW.staff_id, 'GPS Out of Bounds', NEW.status_reason, FALSE);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.on_user_created_provision_wallet()
RETURNS TRIGGER AS $$
DECLARE
    v_signup_bonus INTEGER := 50;
    v_rupee_ratio NUMERIC := 1.0;
    v_customer_exists BOOLEAN := FALSE;
    v_existing_wallet RECORD;
BEGIN
    -- Check if customer already exists in public.customers by mobile matching NEW.phone
    SELECT EXISTS (
        SELECT 1 FROM public.customers WHERE mobile = NEW.phone
    ) INTO v_customer_exists;

    -- Fetch signup settings
    SELECT COALESCE(signup_bonus, 50), COALESCE((coin_ratio_rupees / coin_ratio_coins), 1.0)
    INTO v_signup_bonus, v_rupee_ratio
    FROM public.cheesy_wallet_settings
    WHERE id = 1;

    -- If customer already exists, do NOT grant the welcome signup bonus!
    IF v_customer_exists THEN
        -- Create wallet with 0 coins
        INSERT INTO public.cheesy_wallets (user_id, available_coins, lifetime_earned, lifetime_redeemed, wallet_status)
        VALUES (NEW.id, 0, 0, 0, 'active')
        ON CONFLICT (user_id) DO NOTHING;

        -- Insert audit transaction entry for merge
        INSERT INTO public.cheesy_wallet_transactions (user_id, transaction_type, coins, rupee_value, reference_type, reference_id, remarks)
        VALUES (NEW.id, 'adjustment', 0, 0.0, 'bonus', 'UPGRADE', 'Customer Profile Upgraded POS -> Website. Wallet Preserved. No Welcome Bonus Applied (Reason: Existing Customer).');

        -- Log in customer_rewards_log
        INSERT INTO public.customer_rewards_log (user_id, reward_type, status, source, coins)
        VALUES (NEW.id, 'Signup Bonus', 'Skipped', 'Website', 0);
    ELSE
        -- Create wallet with signup bonus
        INSERT INTO public.cheesy_wallets (user_id, available_coins, lifetime_earned, lifetime_redeemed, wallet_status)
        VALUES (NEW.id, v_signup_bonus, v_signup_bonus, 0, 'active')
        ON CONFLICT (user_id) DO NOTHING;

        -- Insert transaction log
        IF v_signup_bonus > 0 THEN
            INSERT INTO public.cheesy_wallet_transactions (user_id, transaction_type, coins, rupee_value, reference_type, reference_id, remarks)
            VALUES (NEW.id, 'bonus', v_signup_bonus, v_signup_bonus * v_rupee_ratio, 'bonus', 'SIGNUP', 'Welcome Signup Bonus Coins!');

            -- Log in customer_rewards_log
            INSERT INTO public.customer_rewards_log (user_id, reward_type, status, source, coins)
            VALUES (NEW.id, 'Signup Bonus', 'Granted', 'Website', v_signup_bonus);
        END IF;
    END IF;

    -- Automatically upgrade existing customers' sources to 'Both' if they just registered on the website
    IF v_customer_exists THEN
        UPDATE public.customers
        SET source = 'Both'
        WHERE mobile = NEW.phone;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.handle_order_coins_trigger()
RETURNS TRIGGER AS $$
DECLARE
    v_calculated_coins INTEGER := 0;
    v_settings RECORD;
    v_user_id BIGINT;
    v_phone TEXT;
    v_rupee_ratio NUMERIC := 1.0;
    v_enable_loyalty BOOLEAN := TRUE;
    v_min_bill NUMERIC := 0.0;
    v_max_coins INTEGER := 100;
    v_eligible_channels TEXT[];
    v_channel TEXT := 'Website';
    v_earn_mode TEXT := 'ratio';
    v_spend_amount NUMERIC := 100.0;
    v_earn_coins INTEGER := 5;
    v_subtotal NUMERIC := 0.0;
    v_is_eligible_channel BOOLEAN := FALSE;
    v_ref_num TEXT := '';
BEGIN
    -- Extract phone and user_id depending on TG_TABLE_NAME
    IF TG_TABLE_NAME = 'orders' THEN
        v_phone := NEW.phone;
        v_user_id := NEW.user_id;
        v_channel := 'Website';
        v_subtotal := COALESCE(NEW.subtotal, 0.0);
        v_ref_num := COALESCE(NEW.payment_reference, NEW.id::text);
    ELSIF TG_TABLE_NAME = 'pos_orders' THEN
        v_phone := NEW.phone;
        v_user_id := NULL;
        v_channel := 'POS';
        v_subtotal := COALESCE(NEW.subtotal, 0.0);
        v_ref_num := NEW.id::text;
    END IF;

    -- Clean phone number format
    IF v_phone IS NOT NULL THEN
        v_phone := regexp_replace(v_phone, '\D', '', 'g');
        IF starts_with(v_phone, '91') AND length(v_phone) = 12 THEN
            v_phone := substr(v_phone, 3);
        END IF;
    END IF;

    -- Skip if invalid or Walk-in
    IF v_phone IS NULL OR v_phone = '' OR v_phone = 'Walk-in' THEN
        RETURN NEW;
    END IF;

    -- Verify if v_user_id exists in users table
    IF v_user_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = v_user_id) THEN
            v_user_id := NULL;
        END IF;
    END IF;

    -- Resolve user_id if not present
    IF v_user_id IS NULL THEN
        SELECT id INTO v_user_id FROM public.users WHERE phone = v_phone LIMIT 1;
    END IF;

    IF v_user_id IS NULL THEN
        INSERT INTO public.users (name, phone, role)
        VALUES ('POS Customer', v_phone, 'customer')
        ON CONFLICT (phone) DO UPDATE SET updated_at = NOW()
        RETURNING id INTO v_user_id;
    END IF;

    IF TG_TABLE_NAME = 'orders' THEN
        NEW.user_id := v_user_id;
    END IF;

    -- PROCESS REWARDS EARNING ONLY ON ORDER COMPLETION (ZERO DEBITS/REDEMPTIONS IN TRIGGER)
    IF TG_OP = 'INSERT' OR (OLD.status IS DISTINCT FROM NEW.status) THEN
        IF NEW.status IN ('Closed', 'Completed', 'Delivered', 'Picked Up') THEN
            SELECT * INTO v_settings FROM public.cheesy_wallet_settings WHERE id = 1 LIMIT 1;
            IF v_settings IS NOT NULL THEN
                v_enable_loyalty := COALESCE(v_settings.enable_loyalty, TRUE);
                v_min_bill := COALESCE(v_settings.min_order_value, 199.0);
                v_max_coins := COALESCE(v_settings.max_coins_per_order, 100);
                v_eligible_channels := v_settings.eligible_channels;
                v_earn_mode := COALESCE(v_settings.earn_mode, 'ratio');
                v_spend_amount := COALESCE(v_settings.spend_amount, 100.0);
                v_earn_coins := COALESCE(v_settings.earn_coins, 5);
                v_rupee_ratio := COALESCE((v_settings.coin_ratio_rupees / NULLIF(v_settings.coin_ratio_coins, 0)), 1.0);
            END IF;

            IF NOT v_enable_loyalty THEN
                RETURN NEW;
            END IF;

            IF v_subtotal < v_min_bill THEN
                RETURN NEW;
            END IF;

            IF v_eligible_channels IS NOT NULL THEN
                SELECT v_channel = ANY(v_eligible_channels) INTO v_is_eligible_channel;
                IF NOT v_is_eligible_channel THEN
                    RETURN NEW;
                END IF;
            ELSE
                v_is_eligible_channel := TRUE;
            END IF;

            IF NOT EXISTS (SELECT 1 FROM public.cheesy_wallets WHERE user_id = v_user_id) THEN
                INSERT INTO public.cheesy_wallets (user_id, available_coins, lifetime_earned, lifetime_redeemed, wallet_status)
                VALUES (v_user_id, 0, 0, 0, 'active')
                ON CONFLICT (user_id) DO NOTHING;
            END IF;

            IF v_earn_mode = 'ratio' THEN
                IF v_spend_amount > 0 THEN
                    v_calculated_coins := floor(v_subtotal / v_spend_amount) * v_earn_coins;
                END IF;
            ELSIF v_earn_mode = 'percent' THEN
                v_calculated_coins := floor(v_subtotal * (v_earn_coins::numeric / 100.0));
            ELSIF v_earn_mode = 'flat' THEN
                v_calculated_coins := v_earn_coins;
            END IF;

            IF v_calculated_coins > v_max_coins THEN
                v_calculated_coins := v_max_coins;
            END IF;

            IF v_calculated_coins > 0 THEN
                IF NOT EXISTS (
                    SELECT 1 FROM public.cheesy_wallet_transactions 
                    WHERE user_id = v_user_id 
                      AND reference_type = 'order' 
                      AND reference_id = NEW.id::text
                      AND transaction_type = 'earn'
                ) THEN
                    UPDATE public.cheesy_wallets
                    SET available_coins = available_coins + v_calculated_coins,
                        lifetime_earned = lifetime_earned + v_calculated_coins,
                        updated_at = NOW()
                    WHERE user_id = v_user_id;

                    INSERT INTO public.cheesy_wallet_transactions (
                        user_id, transaction_type, coins, rupee_value, reference_type, reference_id, remarks
                    )
                    VALUES (
                        v_user_id, 'earn', v_calculated_coins, v_calculated_coins * v_rupee_ratio, 'order', NEW.id::text, 
                        'Earned from order #' || v_ref_num
                    );
                END IF;
            END IF;
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.cleanup_stale_sessions()
RETURNS TRIGGER AS $$
BEGIN
    DELETE FROM public.active_sessions WHERE expires_at < NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.secure_update_order_status(
    p_order_id BIGINT,
    p_source TEXT,
    p_status TEXT,
    p_session_token TEXT
)
RETURNS JSONB AS $$
DECLARE
    v_session RECORD;
    v_user RECORD;
BEGIN
    SELECT * INTO v_session 
    FROM public.active_sessions 
    WHERE token = p_session_token AND expires_at > NOW() 
    LIMIT 1;

    IF v_session IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid or expired session');
    END IF;

    SELECT * INTO v_user 
    FROM public.users 
    WHERE id = v_session.user_id 
    LIMIT 1;

    IF v_user IS NULL OR v_user.role NOT IN ('super_admin', 'admin', 'manager', 'staff_admin', 'pos_staff', 'kitchen_staff', 'delivery_staff') THEN
        RETURN jsonb_build_object('success', false, 'error', 'Unauthorized to update order status');
    END IF;

    IF p_source = 'POS' THEN
        UPDATE public.pos_orders SET status = UPPER(p_status) WHERE id = p_order_id;
    ELSE
        UPDATE public.orders SET status = UPPER(p_status), order_status = UPPER(p_status) WHERE id = p_order_id;
    END IF;

    INSERT INTO public.system_audit_logs (user_name, user_role, action, device, details)
    VALUES (v_user.full_name, v_user.role, 'update_order_status', v_session.device, jsonb_build_object('order_id', p_order_id, 'source', p_source, 'status', UPPER(p_status)));

    RETURN jsonb_build_object('success', true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.secure_credit_manual_coins(
    p_target_user_id BIGINT,
    p_coins INTEGER,
    p_transaction_type TEXT,
    p_remarks TEXT,
    p_session_token TEXT
)
RETURNS JSONB AS $$
DECLARE
    v_session RECORD;
    v_user RECORD;
    v_settings RECORD;
    v_ratio NUMERIC := 1.0;
    v_rupee_val NUMERIC;
    v_current_avail INT := 0;
    v_current_life INT := 0;
    v_new_avail INT;
    v_new_life INT;
BEGIN
    -- Validate session
    SELECT * INTO v_session 
    FROM public.active_sessions 
    WHERE token = p_session_token AND expires_at > NOW() 
    LIMIT 1;

    IF v_session IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid or expired session');
    END IF;

    -- Validate role (only super_admin, admin, or manager)
    SELECT * INTO v_user 
    FROM public.users 
    WHERE id = v_session.user_id 
    LIMIT 1;

    IF v_user IS NULL OR v_user.role NOT IN ('super_admin', 'admin', 'manager') THEN
        RETURN jsonb_build_object('success', false, 'error', 'Unauthorized to adjust user wallets');
    END IF;

    -- Fetch wallet settings
    SELECT * INTO v_settings FROM public.cheesy_wallet_settings WHERE id = 1 LIMIT 1;
    IF v_settings IS NOT NULL THEN
        v_ratio := v_settings.coin_ratio_rupees / v_settings.coin_ratio_coins;
    END IF;
    v_rupee_val := p_coins * v_ratio;

    -- Log transaction
    INSERT INTO public.cheesy_wallet_transactions (user_id, transaction_type, coins, rupee_value, reference_type, reference_id, remarks)
    VALUES (p_target_user_id, COALESCE(p_transaction_type, 'adjustment'), p_coins, v_rupee_val, 'admin', v_user.full_name, COALESCE(p_remarks, 'Manual adjustment by Admin'));

    -- Ensure wallet exists
    IF NOT EXISTS (SELECT 1 FROM public.cheesy_wallets WHERE user_id = p_target_user_id) THEN
        INSERT INTO public.cheesy_wallets (user_id, available_coins, lifetime_earned, lifetime_redeemed, wallet_status)
        VALUES (p_target_user_id, 0, 0, 0, 'active') ON CONFLICT (user_id) DO NOTHING;
    END IF;

    -- Update wallet
    SELECT available_coins, lifetime_earned INTO v_current_avail, v_current_life
    FROM public.cheesy_wallets
    WHERE user_id = p_target_user_id;

    v_new_avail := GREATEST(0, v_current_avail + p_coins);
    IF p_coins > 0 THEN
        v_new_life := v_current_life + p_coins;
    ELSE
        v_new_life := v_current_life;
    END IF;

    UPDATE public.cheesy_wallets
    SET available_coins = v_new_avail,
        lifetime_earned = v_new_life,
        updated_at = NOW()
    WHERE user_id = p_target_user_id;

    -- Log audit action
    INSERT INTO public.system_audit_logs (user_name, user_role, action, device, details)
    VALUES (v_user.full_name, v_user.role, 'adjust_wallet_balance', v_session.device, jsonb_build_object('target_user_id', p_target_user_id, 'coins', p_coins, 'remarks', p_remarks));

    RETURN jsonb_build_object('success', true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.secure_toggle_wallet_freeze(
    p_target_user_id BIGINT,
    p_status TEXT, -- 'active' or 'frozen'
    p_session_token TEXT
)
RETURNS JSONB AS $$
DECLARE
    v_session RECORD;
    v_user RECORD;
BEGIN
    -- Validate session
    SELECT * INTO v_session 
    FROM public.active_sessions 
    WHERE token = p_session_token AND expires_at > NOW() 
    LIMIT 1;

    IF v_session IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid or expired session');
    END IF;

    -- Validate role
    SELECT * INTO v_user 
    FROM public.users 
    WHERE id = v_session.user_id 
    LIMIT 1;

    IF v_user IS NULL OR v_user.role NOT IN ('super_admin', 'admin', 'manager') THEN
        RETURN jsonb_build_object('success', false, 'error', 'Unauthorized');
    END IF;

    -- Ensure wallet exists
    IF NOT EXISTS (SELECT 1 FROM public.cheesy_wallets WHERE user_id = p_target_user_id) THEN
        INSERT INTO public.cheesy_wallets (user_id, available_coins, lifetime_earned, lifetime_redeemed, wallet_status)
        VALUES (p_target_user_id, 0, 0, 0, p_status) ON CONFLICT (user_id) DO NOTHING;
    ELSE
        UPDATE public.cheesy_wallets
        SET wallet_status = p_status, updated_at = NOW()
        WHERE user_id = p_target_user_id;
    END IF;

    -- Log audit action
    INSERT INTO public.system_audit_logs (user_name, user_role, action, device, details)
    VALUES (v_user.full_name, v_user.role, 'toggle_wallet_status', v_session.device, jsonb_build_object('target_user_id', p_target_user_id, 'status', p_status));

    RETURN jsonb_build_object('success', true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.get_current_session_token()
RETURNS TEXT AS $$
BEGIN
    RETURN COALESCE(
        current_setting('request.headers', true)::json->>'x-cheesy-token',
        ''
    );
EXCEPTION WHEN OTHERS THEN
    RETURN '';
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION public.get_current_user_id()
RETURNS BIGINT AS $$
DECLARE
    v_token TEXT;
    v_user_id BIGINT;
BEGIN
    v_token := public.get_current_session_token();
    
    IF v_token IS NULL 
       OR v_token = '' 
       OR v_token = 'undefined' 
       OR v_token = 'null' 
    THEN
        RETURN NULL;
    END IF;
    
    SELECT user_id INTO v_user_id 
    FROM public.active_sessions 
    WHERE token = v_token AND expires_at > NOW() 
    LIMIT 1;
    
    RETURN v_user_id;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

CREATE OR REPLACE FUNCTION public.get_current_user_roles()
RETURNS TEXT[] AS $$
DECLARE
    v_user_id BIGINT;
    v_roles TEXT[];
BEGIN
    v_user_id := public.get_current_user_id();
    IF v_user_id IS NULL THEN
        RETURN ARRAY[]::TEXT[];
    END IF;
    
    SELECT array_agg(role) INTO v_roles 
    FROM public.user_roles 
    WHERE user_id = v_user_id AND is_active = true;
    
    RETURN COALESCE(v_roles, ARRAY[]::TEXT[]);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

CREATE OR REPLACE FUNCTION public.is_super_admin()
RETURNS BOOLEAN AS $$
BEGIN
    RETURN 'super_admin' = ANY(public.get_current_user_roles());
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN AS $$
BEGIN
    RETURN 'super_admin' = ANY(public.get_current_user_roles()) OR 'admin' = ANY(public.get_current_user_roles());
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

CREATE OR REPLACE FUNCTION public.get_current_user_branch_id()
RETURNS BIGINT AS $$
DECLARE
    v_branch_id BIGINT;
BEGIN
    SELECT branch_id INTO v_branch_id 
    FROM public.users 
    WHERE id = public.get_current_user_id() 
    LIMIT 1;
    
    RETURN COALESCE(v_branch_id, 1::BIGINT);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

CREATE OR REPLACE FUNCTION public.check_row_branch_access(p_branch_id BIGINT)
RETURNS BOOLEAN AS $$
BEGIN
    IF public.is_super_admin() THEN
        RETURN true;
    END IF;
    RETURN public.get_current_user_branch_id() = p_branch_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

CREATE OR REPLACE FUNCTION public.has_permission(p_permission TEXT)
RETURNS BOOLEAN AS $$
DECLARE
    v_user_id BIGINT;
BEGIN
    v_user_id := public.get_current_user_id();
    IF v_user_id IS NULL THEN
        RETURN false;
    END IF;
    
    IF EXISTS (
        SELECT 1 FROM public.user_roles 
        WHERE user_id = v_user_id AND role = 'super_admin' AND is_active = true
    ) THEN
        RETURN true;
    END IF;
    
    IF EXISTS (
        SELECT 1 FROM public.user_permissions 
        WHERE user_id = v_user_id AND permission_id = p_permission
    ) THEN
        RETURN true;
    END IF;
    
    IF EXISTS (
        SELECT 1 
        FROM public.user_roles ur
        JOIN public.role_permissions rp ON rp.role_id = ur.role
        WHERE ur.user_id = v_user_id 
          AND ur.is_active = true 
          AND rp.permission_id = p_permission
    ) THEN
        RETURN true;
    END IF;
    
    RETURN false;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

CREATE OR REPLACE FUNCTION public.secure_check_permission(p_token TEXT, p_permission TEXT)
RETURNS JSONB AS $$
DECLARE
    v_session RECORD;
    v_user RECORD;
    v_has BOOLEAN := false;
BEGIN
    SELECT * INTO v_session 
    FROM public.active_sessions 
    WHERE token = p_token AND expires_at > NOW() 
    LIMIT 1;

    IF v_session IS NULL THEN
        RETURN jsonb_build_object('valid', false, 'has_permission', false);
    END IF;

    SELECT * INTO v_user 
    FROM public.users 
    WHERE id = v_session.user_id 
    LIMIT 1;

    IF v_user IS NULL THEN
        RETURN jsonb_build_object('valid', false, 'has_permission', false);
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.user_roles 
        WHERE user_id = v_user.id AND role = 'super_admin' AND is_active = true
    ) THEN
        v_has := true;
    ELSIF EXISTS (
        SELECT 1 FROM public.user_permissions 
        WHERE user_id = v_user.id AND permission_id = p_permission
    ) THEN
        v_has := true;
    ELSIF EXISTS (
        SELECT 1 
        FROM public.user_roles ur
        JOIN public.role_permissions rp ON rp.role_id = ur.role
        WHERE ur.user_id = v_user.id 
          AND ur.is_active = true 
          AND rp.permission_id = p_permission
    ) THEN
        v_has := true;
    END IF;

    RETURN jsonb_build_object('valid', true, 'has_permission', v_has);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.secure_internal_login(
    p_login_id TEXT,
    p_password TEXT,
    p_device TEXT DEFAULT 'Unknown Device',
    p_ip TEXT DEFAULT '127.0.0.1',
    p_location TEXT DEFAULT 'Unknown Location'
)
RETURNS JSONB AS $$
DECLARE
    v_clean_login_id TEXT;
    v_user RECORD;
    v_token TEXT;
    v_expires TIMESTAMPTZ;
    v_payload JSONB;
    v_cred_hash TEXT;
    v_match BOOLEAN := FALSE;
BEGIN
    v_clean_login_id := TRIM(COALESCE(p_login_id, ''));

    IF v_clean_login_id = '' OR COALESCE(p_password, '') = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid login credentials');
    END IF;

    IF v_clean_login_id LIKE '+91%' THEN
        v_clean_login_id := substring(v_clean_login_id from 4);
    END IF;

    -- Locate internal user matching email, mobile, phone, or employee_code
    SELECT * INTO v_user 
    FROM public.users 
    WHERE (
        email = v_clean_login_id 
        OR mobile = v_clean_login_id 
        OR phone = v_clean_login_id 
        OR employee_code = v_clean_login_id
        OR REGEXP_REPLACE(COALESCE(phone, ''), '\D', '', 'g') = REGEXP_REPLACE(v_clean_login_id, '\D', '', 'g')
        OR REGEXP_REPLACE(COALESCE(mobile, ''), '\D', '', 'g') = REGEXP_REPLACE(v_clean_login_id, '\D', '', 'g')
    )
      AND (role IS NULL OR role != 'customer')
      AND status = 'active'
    ORDER BY id ASC
    LIMIT 1;

    IF v_user IS NULL THEN
        INSERT INTO public.security_events (event_type, severity, description, ip_address, device, location)
        VALUES ('failed_login', 'medium', 'Attempted login with non-existent or inactive ID: ' || v_clean_login_id, p_ip, p_device, p_location);
        
        RETURN jsonb_build_object('success', false, 'error', 'Invalid login credentials');
    END IF;

    -- Verify password_hash
    IF v_user.password_hash IS NOT NULL AND LENGTH(TRIM(v_user.password_hash)) > 0 THEN
        v_cred_hash := REPLACE(v_user.password_hash, '$2b$', '$2a$');
        IF v_cred_hash = extensions.crypt(p_password, v_cred_hash) THEN
            v_match := TRUE;
        END IF;
    END IF;

    -- Fallback: Verify pin_hash if password_hash didn't match or was missing
    IF NOT v_match AND v_user.pin_hash IS NOT NULL AND LENGTH(TRIM(v_user.pin_hash)) > 0 THEN
        v_cred_hash := REPLACE(v_user.pin_hash, '$2b$', '$2a$');
        IF v_cred_hash = extensions.crypt(p_password, v_cred_hash) THEN
            v_match := TRUE;
        END IF;
    END IF;

    IF NOT v_match THEN
        INSERT INTO public.security_events (user_id, event_type, severity, description, ip_address, device, location)
        VALUES (v_user.id, 'failed_login', 'medium', 'Invalid password for user: ' || COALESCE(v_user.email, v_user.mobile, v_user.full_name, 'Unknown'), p_ip, p_device, p_location);
        
        RETURN jsonb_build_object('success', false, 'error', 'Invalid login credentials');
    END IF;

    -- Terminate previous sessions for this internal user
    DELETE FROM public.active_sessions WHERE user_id = v_user.id;

    v_token := encode(extensions.gen_random_bytes(32), 'hex');
    v_expires := NOW() + INTERVAL '24 hours';

    INSERT INTO public.active_sessions (user_id, token, ip_address, device, location, expires_at)
    VALUES (v_user.id, v_token, p_ip, p_device, p_location, v_expires);

    INSERT INTO public.security_events (user_id, event_type, severity, description, ip_address, device, location)
    VALUES (v_user.id, 'successful_login', 'low', 'User logged in successfully. Previous sessions terminated.', p_ip, p_device, p_location);

    v_payload := jsonb_build_object(
        'success', true,
        'token', v_token,
        'user', jsonb_build_object(
            'id', v_user.id,
            'full_name', COALESCE(v_user.full_name, v_user.name, 'Staff'),
            'email', COALESCE(v_user.email, ''),
            'mobile', COALESCE(v_user.mobile, v_user.phone, ''),
            'role', COALESCE(v_user.role, 'staff'),
            'branch_id', COALESCE(v_user.branch_id, 1),
            'employee_code', COALESCE(v_user.employee_code, ''),
            'roles', (SELECT COALESCE(jsonb_agg(role), jsonb_build_array(COALESCE(v_user.role, 'staff'))) FROM public.user_roles WHERE user_id = v_user.id AND is_active = true)
        )
    );

    RETURN v_payload;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION public.secure_assign_multi_role(
    p_session_token TEXT,
    p_target_user_id BIGINT,
    p_role TEXT,
    p_assign BOOLEAN
)
RETURNS JSONB AS $$
DECLARE
    v_session RECORD;
    v_user RECORD;
    v_target_user RECORD;
BEGIN
    SELECT * INTO v_session 
    FROM public.active_sessions 
    WHERE token = p_session_token AND expires_at > NOW() 
    LIMIT 1;

    IF v_session IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid session');
    END IF;

    SELECT * INTO v_user 
    FROM public.users 
    WHERE id = v_session.user_id 
    LIMIT 1;

    IF v_user IS NULL OR NOT EXISTS (
        SELECT 1 FROM public.user_roles 
        WHERE user_id = v_user.id AND role = 'super_admin' AND is_active = true
    ) THEN
        IF v_user IS NULL OR v_user.role <> 'super_admin' THEN
            RETURN jsonb_build_object('success', false, 'error', 'Only Super Admin can assign or modify roles');
        END IF;
    END IF;

    SELECT * INTO v_target_user 
    FROM public.users 
    WHERE id = p_target_user_id 
    LIMIT 1;

    IF v_target_user IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Target user not found');
    END IF;

    IF p_role = 'super_admin' AND v_target_user.id = v_user.id AND NOT p_assign THEN
        RETURN jsonb_build_object('success', false, 'error', 'Cannot remove your own Super Admin access');
    END IF;

    IF p_assign THEN
        INSERT INTO public.user_roles (user_id, role, assigned_by, assigned_at, is_active)
        VALUES (p_target_user_id, p_role, v_user.id, NOW(), true)
        ON CONFLICT (user_id, role) DO UPDATE 
        SET is_active = true, assigned_by = v_user.id, assigned_at = NOW();

        -- Update the legacy users.role column as well for fallback safety (first active role in list)
        UPDATE public.users SET role = p_role WHERE id = p_target_user_id;

        INSERT INTO public.security_events (user_id, event_type, severity, description)
        VALUES (v_user.id, 'role_assigned', 'medium', 'Assigned role ' || p_role || ' to user ' || v_target_user.full_name);
    ELSE
        DELETE FROM public.user_roles
        WHERE user_id = p_target_user_id AND role = p_role;

        -- Update legacy role column fallback to the first active role remaining, or 'staff'
        UPDATE public.users 
        SET role = COALESCE((SELECT role FROM public.user_roles WHERE user_id = p_target_user_id AND is_active = true LIMIT 1), 'staff')
        WHERE id = p_target_user_id;

        INSERT INTO public.security_events (user_id, event_type, severity, description)
        VALUES (v_user.id, 'role_removed', 'medium', 'Removed role ' || p_role || ' from user ' || v_target_user.full_name);
    END IF;

    RETURN jsonb_build_object('success', true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.secure_delete_user(
    p_session_token TEXT,
    p_target_user_id BIGINT
)
RETURNS JSONB AS $$
DECLARE
    v_session RECORD;
    v_user RECORD;
    v_target_user RECORD;
BEGIN
    SELECT * INTO v_session 
    FROM public.active_sessions 
    WHERE token = p_session_token AND expires_at > NOW() 
    LIMIT 1;

    IF v_session IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid session');
    END IF;

    SELECT * INTO v_user 
    FROM public.users 
    WHERE id = v_session.user_id 
    LIMIT 1;

    IF v_user IS NULL OR NOT EXISTS (
        SELECT 1 FROM public.user_roles 
        WHERE user_id = v_user.id AND role = 'super_admin' AND is_active = true
    ) THEN
        IF v_user IS NULL OR v_user.role <> 'super_admin' THEN
            RETURN jsonb_build_object('success', false, 'error', 'Only Super Admin can delete users');
        END IF;
    END IF;

    SELECT * INTO v_target_user 
    FROM public.users 
    WHERE id = p_target_user_id 
    LIMIT 1;

    IF v_target_user IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'User not found');
    END IF;

    IF v_target_user.id = v_user.id THEN
        RETURN jsonb_build_object('success', false, 'error', 'Cannot delete your own account');
    END IF;

    -- Log event before deletion
    INSERT INTO public.security_events (user_id, event_type, severity, description)
    VALUES (v_user.id, 'user_deleted', 'high', 'Permanently deleted internal user ' || v_target_user.full_name || ' (ID: ' || p_target_user_id || ')');

    -- Cascade delete records
    DELETE FROM public.active_sessions WHERE user_id = p_target_user_id;
    DELETE FROM public.user_roles WHERE user_id = p_target_user_id;
    DELETE FROM public.staff_profiles WHERE id = p_target_user_id;
    DELETE FROM public.users WHERE id = p_target_user_id;

    RETURN jsonb_build_object('success', true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.secure_log_audit(
    p_action TEXT,
    p_route TEXT,
    p_details JSONB,
    p_ip_address TEXT DEFAULT NULL,
    p_device TEXT DEFAULT NULL,
    p_browser TEXT DEFAULT NULL
)
RETURNS VOID AS $$
DECLARE
    v_token TEXT;
    v_user_id BIGINT;
    v_session RECORD;
    v_ip TEXT;
    v_dev TEXT;
BEGIN
    v_token := public.get_current_session_token();
    
    IF v_token IS NOT NULL AND v_token <> '' THEN
        SELECT * INTO v_session FROM public.active_sessions WHERE token = v_token LIMIT 1;
        IF v_session IS NOT NULL THEN
            v_user_id := v_session.user_id;
            v_ip := COALESCE(p_ip_address, v_session.ip_address);
            v_dev := COALESCE(p_device, v_session.device);
        END IF;
    END IF;
    
    INSERT INTO public.security_events (
        user_id,
        event_type,
        severity,
        description,
        ip_address,
        device,
        location,
        created_at
    )
    VALUES (
        v_user_id,
        p_action,
        CASE 
            WHEN p_action IN ('unauthorized_access_attempt', 'direct_url_bypass_attempt', 'role_violation', 'permission_violation') THEN 'high'
            ELSE 'low'
        END,
        COALESCE(p_details->>'reason', p_action) || ' on route: ' || COALESCE(p_route, 'unknown') || ' (Browser: ' || COALESCE(p_browser, 'unknown') || ')',
        COALESCE(v_ip, '127.0.0.1'),
        COALESCE(v_dev, 'Unknown Device'),
        p_details::text,
        NOW()
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.sync_staff_profiles_insert()
RETURNS TRIGGER AS $$
DECLARE
    v_user_id BIGINT;
    v_existing_user_id BIGINT;
BEGIN
    -- Prevent infinite recursion
    IF pg_trigger_depth() > 1 THEN
        RETURN NEW;
    END IF;

    -- Check if user already exists in users table by mobile
    SELECT id INTO v_existing_user_id FROM public.users WHERE mobile = NEW.mobile LIMIT 1;
    
    IF v_existing_user_id IS NOT NULL THEN
        -- Link staff profile to the existing user
        NEW.id := v_existing_user_id;
        
        -- Update user status, name, and role (preserving higher roles like super_admin, admin, manager etc.)
        UPDATE public.users 
        SET role = COALESCE(NULLIF(role, 'customer'), 'staff'),
            status = 'active',
            full_name = NEW.full_name,
            password_hash = CASE WHEN NEW.password_hash IS NOT NULL AND NEW.password_hash <> '' THEN NEW.password_hash ELSE password_hash END
        WHERE id = v_existing_user_id;
    ELSE
        -- Insert new user
        INSERT INTO public.users (full_name, mobile, password_hash, role, branch_id, status)
        VALUES (NEW.full_name, NEW.mobile, NEW.password_hash, 'staff', 1, 'active')
        RETURNING id INTO v_user_id;
        
        NEW.id := v_user_id;
    END IF;
    
    -- Auto-provision their user_role mapping as staff
    INSERT INTO public.user_roles (user_id, role, is_active)
    VALUES (NEW.id, 'staff', TRUE)
    ON CONFLICT DO NOTHING;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.sync_staff_profiles_update()
RETURNS TRIGGER AS $$
BEGIN
    -- Prevent infinite recursion
    IF pg_trigger_depth() > 1 THEN
        RETURN NEW;
    END IF;

    UPDATE public.users 
    SET full_name = NEW.full_name,
        mobile = NEW.mobile,
        password_hash = CASE WHEN NEW.password_hash IS NOT NULL AND NEW.password_hash <> '' THEN NEW.password_hash ELSE password_hash END,
        status = CASE WHEN NEW.status = 'Active' THEN 'active' ELSE 'suspended' END
    WHERE id = NEW.id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.sync_staff_profiles_delete()
RETURNS TRIGGER AS $$
BEGIN
    -- Prevent infinite recursion
    IF pg_trigger_depth() > 1 THEN
        RETURN OLD;
    END IF;

    IF EXISTS (SELECT 1 FROM public.users WHERE id = OLD.id) THEN
        DELETE FROM public.users WHERE id = OLD.id;
    END IF;
    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.sync_inventory_topup_stock()
RETURNS TRIGGER AS $$
DECLARE
    v_staff_id BIGINT;
    v_date DATE;
    v_item_type TEXT;
    v_total_topup NUMERIC := 0;
    v_staff_name TEXT;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_staff_id := OLD.staff_id;
        v_date := OLD.date;
        v_item_type := OLD.item_type;
    ELSE
        v_staff_id := NEW.staff_id;
        v_date := NEW.date;
        v_item_type := NEW.item_type;
    END IF;

    -- Get staff name
    SELECT full_name INTO v_staff_name FROM public.staff_profiles WHERE id = v_staff_id LIMIT 1;

    -- Calculate total from inventory_topups
    SELECT COALESCE(SUM(quantity), 0) INTO v_total_topup 
    FROM public.inventory_topups 
    WHERE staff_id = v_staff_id AND date = v_date AND item_type = v_item_type;

    -- Update or insert daily_inventory_logs
    INSERT INTO public.daily_inventory_logs (date, staff_id, staff_name, item_type, topup_stock)
    VALUES (v_date, v_staff_id, v_staff_name, v_item_type, v_total_topup)
    ON CONFLICT (date, staff_id, item_type) 
    DO UPDATE SET 
        topup_stock = EXCLUDED.topup_stock, 
        staff_name = COALESCE(EXCLUDED.staff_name, daily_inventory_logs.staff_name),
        expected_closing = daily_inventory_logs.opening_stock + EXCLUDED.topup_stock - daily_inventory_logs.consumption,
        variance = daily_inventory_logs.closing_stock - (daily_inventory_logs.opening_stock + EXCLUDED.topup_stock - daily_inventory_logs.consumption),
        updated_at = NOW();

    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.sync_users_to_staff_profiles()
RETURNS TRIGGER AS $$
BEGIN
    -- Prevent infinite recursion
    IF pg_trigger_depth() > 1 THEN
        RETURN NEW;
    END IF;

    -- Only sync users with role other than 'customer' (i.e. staff, admin, managers, pos, kitchen, delivery etc.)
    IF NEW.role IS DISTINCT FROM 'customer' THEN
        INSERT INTO public.staff_profiles (
            id,
            full_name,
            mobile,
            status,
            password_hash,
            profile_photo,
            joining_date,
            updated_at
        )
        VALUES (
            NEW.id,
            NEW.full_name,
            NEW.mobile,
            CASE WHEN NEW.status = 'active' THEN 'Active' ELSE 'Suspended' END,
            NEW.password_hash,
            'https://images.unsplash.com/photo-1577219491135-ce391730fb2c?w=150',
            CURRENT_DATE,
            NOW()
        )
        ON CONFLICT (id) DO UPDATE
        SET full_name = EXCLUDED.full_name,
            mobile = EXCLUDED.mobile,
            status = EXCLUDED.status,
            password_hash = CASE WHEN EXCLUDED.password_hash IS NOT NULL AND EXCLUDED.password_hash <> '' THEN EXCLUDED.password_hash ELSE public.staff_profiles.password_hash END,
            updated_at = NOW();
    ELSE
        -- If their role is 'customer', ensure they do not have a staff profile
        DELETE FROM public.staff_profiles WHERE id = NEW.id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.calculate_distance_km(
    lat1 NUMERIC, 
    lon1 NUMERIC, 
    lat2 NUMERIC, 
    lon2 NUMERIC
)
RETURNS NUMERIC AS $$
DECLARE
    R NUMERIC := 6371.0; -- Earth radius in KM
    phi1 NUMERIC := RADIANS(lat1);
    phi2 NUMERIC := RADIANS(lat2);
    deltaPhi NUMERIC := RADIANS(lat2 - lat1);
    deltaLambda NUMERIC := RADIANS(lon2 - lon1);
    a NUMERIC;
    c NUMERIC;
BEGIN
    a := SIN(deltaPhi / 2) * SIN(deltaPhi / 2) +
         COS(phi1) * COS(phi2) *
         SIN(deltaLambda / 2) * SIN(deltaLambda / 2);
    c := 2 * ATAN2(SQRT(a), SQRT(1 - a));
    RETURN ROUND((R * c)::NUMERIC, 2);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION public.secure_create_order(
    p_items JSONB,
    p_delivery_mode TEXT,
    p_address TEXT,
    p_landmark TEXT,
    p_payment_method TEXT,
    p_coupon_code TEXT,
    p_use_wallet BOOLEAN,
    p_session_token TEXT,
    p_address_id BIGINT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_session RECORD;
    v_user RECORD;
    v_item RECORD;
    v_subtotal NUMERIC := 0.0;
    v_item_price NUMERIC;
    v_item_total NUMERIC;
    v_addon_price NUMERIC;
    v_addon_id BIGINT;
    v_addon RECORD;
    v_delivery_fee NUMERIC := 0.0;
    v_delivery_settings RECORD;
    v_gst NUMERIC := 0.0;
    v_coupon_discount NUMERIC := 0.0;
    v_coupon_res JSONB;
    v_wallet RECORD;
    v_wallet_settings RECORD;
    v_wallet_redeem_coins INT := 0;
    v_wallet_redeem_rupees NUMERIC := 0.0;
    v_final_total NUMERIC := 0.0;
    v_order_id BIGINT;
    v_items_count INT;
    v_variant_name TEXT;
    v_addons_names TEXT;
    v_item_data JSONB;
    v_addon_data JSONB;
    v_order_item_id BIGINT;
    
    -- Location variables
    v_addr_lat NUMERIC := NULL;
    v_addr_lng NUMERIC := NULL;
    v_addr_map_link TEXT := NULL;
    v_distance NUMERIC := NULL;
    v_slab_charge NUMERIC := NULL;
    v_slab RECORD;
    v_slab_free_above NUMERIC := NULL;
    v_slab_matched BOOLEAN := FALSE;
    v_req_free_above NUMERIC := NULL;
BEGIN
    -- 1. Validate Session Token
    SELECT * INTO v_session 
    FROM public.active_sessions 
    WHERE token = p_session_token AND expires_at > NOW() 
    LIMIT 1;

    IF v_session IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Session expired or invalid. Please log in again.');
    END IF;

    -- Secure user load
    SELECT * INTO v_user 
    FROM public.users 
    WHERE id = v_session.user_id 
    LIMIT 1;

    IF v_user IS NULL OR v_user.status <> 'active' THEN
        RETURN jsonb_build_object('success', false, 'error', 'User account is suspended or invalid.');
    END IF;

    -- 2. Calculate Subtotal and Verify Item Prices Server-Side
    v_items_count := jsonb_array_length(p_items);
    IF v_items_count = 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'Order cart is empty.');
    END IF;

    FOR i IN 0..(v_items_count - 1) LOOP
        v_item_data := p_items->i;
        
        -- Get product base price
        SELECT price INTO v_item_price 
        FROM public.products 
        WHERE id = (v_item_data->>'product_id')::BIGINT AND is_active = TRUE;

        IF v_item_price IS NULL THEN
            IF (v_item_data->>'isFreeGift')::BOOLEAN = TRUE THEN
                v_item_price := 0.0;
            ELSE
                RETURN jsonb_build_object('success', false, 'error', 'Product ' || (v_item_data->>'name') || ' is no longer available.');
            END IF;
        END IF;

        -- Verify variant price if specified
        v_variant_name := '';
        IF v_item_data->'variant' IS NOT NULL AND (v_item_data->'variant'->>'id') IS NOT NULL AND (v_item_data->'variant'->>'id') <> '' THEN
            v_variant_name := v_item_data->'variant'->>'name';
            SELECT price INTO v_item_price 
            FROM public.product_variants 
            WHERE id = (v_item_data->'variant'->>'id')::BIGINT;
            
            IF v_item_price IS NULL THEN
                RETURN jsonb_build_object('success', false, 'error', 'Product variant ' || v_variant_name || ' is invalid.');
            END IF;
        END IF;

        -- Verify Add-on prices
        v_addon_price := 0.0;
        IF v_item_data->'addons' IS NOT NULL AND jsonb_array_length(v_item_data->'addons') > 0 THEN
            FOR j IN 0..(jsonb_array_length(v_item_data->'addons') - 1) LOOP
                v_addon_data := v_item_data->'addons'->j;
                v_addon_id := (v_addon_data->>'id')::BIGINT;
                
                SELECT * INTO v_addon 
                FROM public.addons 
                WHERE id = v_addon_id;

                IF v_addon IS NOT NULL THEN
                    IF LOWER(v_variant_name) = 'small' AND v_addon.small_price IS NOT NULL THEN
                        v_addon_price := v_addon_price + v_addon.small_price;
                    ELSIF LOWER(v_variant_name) = 'medium' AND v_addon.medium_price IS NOT NULL THEN
                        v_addon_price := v_addon_price + v_addon.medium_price;
                    ELSE
                        v_addon_price := v_addon_price + COALESCE(v_addon.price, 0.0);
                    END IF;
                END IF;
            END LOOP;
        END IF;

        -- For meals/combos, add upgrade charges to the base item price dynamically
        IF v_item_data->'meal_configurations' IS NOT NULL AND jsonb_array_length(v_item_data->'meal_configurations') > 0 THEN
            DECLARE
                v_meal_cfg JSONB;
                v_item_elem JSONB;
                v_upgrade_sum NUMERIC := 0.0;
                v_included_prod_id BIGINT;
                v_upgrade_prod_id BIGINT;
                v_calc_charge NUMERIC := 0.0;
            BEGIN
                FOR j IN 0..(jsonb_array_length(v_item_data->'meal_configurations') - 1) LOOP
                    v_meal_cfg := v_item_data->'meal_configurations'->j;
                    IF v_meal_cfg->'selected_items' IS NOT NULL THEN
                        FOR k IN 0..(jsonb_array_length(v_meal_cfg->'selected_items') - 1) LOOP
                            v_item_elem := v_meal_cfg->'selected_items'->k;
                            
                            -- Check if it contains upgrade fields
                            IF v_item_elem->>'included_product_id' IS NOT NULL AND v_item_elem->>'upgrade_product_id' IS NOT NULL THEN
                                v_included_prod_id := (v_item_elem->>'included_product_id')::BIGINT;
                                v_upgrade_prod_id := (v_item_elem->>'upgrade_product_id')::BIGINT;
                                
                                IF v_included_prod_id = v_upgrade_prod_id THEN
                                    v_calc_charge := 0.0;
                                ELSE
                                    -- Query price from product_upgrade_mapping
                                    SELECT upgrade_price INTO v_calc_charge
                                    FROM public.product_upgrade_mapping
                                    WHERE base_product_id = v_included_prod_id AND upgrade_product_id = v_upgrade_prod_id AND is_active = TRUE
                                    LIMIT 1;
                                    
                                    v_calc_charge := COALESCE(v_calc_charge, 0.0);
                                END IF;
                                v_upgrade_sum := v_upgrade_sum + v_calc_charge;
                            END IF;
                        END LOOP;
                    END IF;
                END LOOP;
                v_item_price := v_item_price + v_upgrade_sum;
            END;
        END IF;

        v_item_total := (v_item_price + v_addon_price) * (v_item_data->>'quantity')::INTEGER;
        v_subtotal := v_subtotal + v_item_total;
    END LOOP;

    -- 3. Load Delivery Settings and Compute Delivery Fee
    SELECT * INTO v_delivery_settings 
    FROM public.delivery_settings 
    LIMIT 1;

    IF p_delivery_mode IN ('delivery', 'schedule') THEN
        -- Enforce global minimum order threshold for delivery
        IF v_subtotal < COALESCE(v_delivery_settings.minimum_order, 0.0) THEN
            RETURN jsonb_build_object('success', false, 'error', 'Minimum order amount for delivery is ₹' || COALESCE(v_delivery_settings.minimum_order, 0.0) || '. Please add more items.');
        END IF;

        -- Securely calculate distance and match distance slabs if address id is provided
        IF p_address_id IS NOT NULL THEN
            SELECT latitude, longitude, map_link INTO v_addr_lat, v_addr_lng, v_addr_map_link
            FROM public.addresses
            WHERE id = p_address_id AND user_id = v_user.id;
            
            IF v_addr_lat IS NOT NULL AND v_addr_lng IS NOT NULL THEN
                v_distance := public.calculate_distance_km(
                    v_addr_lat, 
                    v_addr_lng, 
                    COALESCE(v_delivery_settings.gps_lat, 27.800872), 
                    COALESCE(v_delivery_settings.gps_lng, 76.648441)
                );
                
                -- Match dynamic distance slabs
                IF v_delivery_settings.distance_slabs IS NOT NULL THEN
                    FOR v_slab IN SELECT * FROM jsonb_to_recordset(v_delivery_settings.distance_slabs) AS (min NUMERIC, max NUMERIC, charge NUMERIC, free_above NUMERIC) LOOP
                        IF v_distance >= v_slab.min AND v_distance < v_slab.max THEN
                            v_slab_charge := v_slab.charge;
                            v_slab_free_above := v_slab.free_above;
                            v_slab_matched := TRUE;
                            EXIT;
                        END IF;
                    END LOOP;
                END IF;

                IF NOT v_slab_matched THEN
                    RETURN jsonb_build_object('success', false, 'error', 'Sorry, delivery is unavailable at this location (Outside configured delivery zones).');
                END IF;

                v_delivery_fee := COALESCE(v_slab_charge, 0.0);
                
                -- Enforce slab-specific free delivery threshold
                v_req_free_above := v_slab_free_above;
                IF v_req_free_above IS NOT NULL AND v_req_free_above > 0 AND v_subtotal >= v_req_free_above THEN
                    v_delivery_fee := 0.0;
                END IF;
            ELSE
                RETURN jsonb_build_object('success', false, 'error', 'Delivery address latitude/longitude are invalid.');
            END IF;
        ELSE
            RETURN jsonb_build_object('success', false, 'error', 'Delivery address is required.');
        END IF;
    END IF;

    -- 4. Calculate GST (5% standard)
    v_gst := ROUND(v_subtotal * 0.05, 2);

    -- 5. Validate and Calculate Coupon Discount
    IF p_coupon_code IS NOT NULL AND p_coupon_code <> '' THEN
        v_coupon_res := public.secure_validate_coupon(p_coupon_code, v_subtotal, v_user.id);
        
        IF (v_coupon_res->>'valid')::BOOLEAN = TRUE THEN
            IF v_coupon_res->>'discount_type' = 'percentage' THEN
                v_coupon_discount := ROUND(v_subtotal * ((v_coupon_res->>'discount_value')::NUMERIC / 100.0), 2);
                IF (v_coupon_res->>'max_discount') IS NOT NULL THEN
                    v_coupon_discount := LEAST(v_coupon_discount, (v_coupon_res->>'max_discount')::NUMERIC);
                END IF;
            ELSIF v_coupon_res->>'discount_type' = 'flat' THEN
                v_coupon_discount := LEAST((v_coupon_res->>'discount_value')::NUMERIC, v_subtotal);
            END IF;
        ELSE
            INSERT INTO public.security_events (user_id, event_type, severity, description)
            VALUES (v_user.id, 'coupon_abuse', 'medium', 'Failed attempt to apply coupon ' || p_coupon_code || '. Reason: ' || (v_coupon_res->>'error'));
        END IF;
    END IF;

    -- 6. Validate Wallet Redemption
    IF p_use_wallet = TRUE THEN
        SELECT * INTO v_wallet 
        FROM public.cheesy_wallets 
        WHERE user_id = v_user.id AND wallet_status = 'active';

        SELECT * INTO v_wallet_settings 
        FROM public.cheesy_wallet_settings 
        LIMIT 1;

        IF v_wallet IS NOT NULL AND v_wallet_settings IS NOT NULL AND v_wallet.available_coins > 0 THEN
            IF v_subtotal >= v_wallet_settings.min_order_value THEN
                DECLARE
                    v_max_rupee_discount NUMERIC;
                    v_coins_needed INT;
                BEGIN
                    v_max_rupee_discount := ROUND(v_subtotal * (v_wallet_settings.max_redeem_percent / 100.0), 2);
                    v_coins_needed := CEIL(v_max_rupee_discount * (v_wallet_settings.coin_ratio_coins / v_wallet_settings.coin_ratio_rupees));
                    
                    v_wallet_redeem_coins := LEAST(v_wallet.available_coins, v_coins_needed);
                    v_wallet_redeem_rupees := ROUND(v_wallet_redeem_coins * (v_wallet_settings.coin_ratio_rupees / v_wallet_settings.coin_ratio_coins), 2);
                END;
            END IF;
        END IF;
    END IF;

    -- 7. Calculate Final Total
    v_final_total := v_subtotal + v_gst + v_delivery_fee - v_coupon_discount - v_wallet_redeem_rupees;
    IF v_final_total < 0 THEN
        v_final_total := 0.0;
    END IF;

    -- 8. Insert Order Record securely
    INSERT INTO public.orders (
        user_id, customer_name, phone, address, landmark, 
        payment_method, payment_status, subtotal, gst, delivery_fee, 
        total, status, delivery_mode, coupon_code, coupon_discount, 
        coins_redeemed, coins_earned, order_source,
        latitude, longitude, distance_km, google_map_link
    ) VALUES (
        v_user.id, v_user.full_name, v_user.mobile, p_address, p_landmark,
        p_payment_method, 'Paid', v_subtotal, v_gst, v_delivery_fee,
        v_final_total, 'Pending', p_delivery_mode, p_coupon_code, v_coupon_discount,
        v_wallet_redeem_coins, 0, 'online',
        v_addr_lat, v_addr_lng, v_distance, v_addr_map_link
    ) RETURNING id INTO v_order_id;

    -- Update last_used_at timestamp on saved address if relevant
    IF p_address_id IS NOT NULL THEN
        UPDATE public.addresses SET last_used_at = NOW() WHERE id = p_address_id;
    END IF;

    -- 9. Insert Order Items Records
    FOR i IN 0..(v_items_count - 1) LOOP
        v_item_data := p_items->i;
        v_item_price := (v_item_data->>'price')::NUMERIC;
        v_variant_name := COALESCE(v_item_data->'variant'->>'name', '');

        -- Format addons / meal configurations text
        v_addons_names := '';
        IF v_item_data->'meal_configurations' IS NOT NULL AND jsonb_array_length(v_item_data->'meal_configurations') > 0 THEN
            DECLARE
                v_meal_cfg JSONB;
                v_group_name TEXT;
                v_item_names TEXT := '';
                v_formatted_cfgs TEXT := '';
                v_group_id BIGINT;
            BEGIN
                FOR j IN 0..(jsonb_array_length(v_item_data->'meal_configurations') - 1) LOOP
                    v_meal_cfg := v_item_data->'meal_configurations'->j;
                    v_group_name := v_meal_cfg->>'group_name';
                    v_group_id := (v_meal_cfg->>'group_id')::BIGINT;
                    v_item_names := '';
                    
                    IF v_meal_cfg->'selected_items' IS NOT NULL AND jsonb_array_length(v_meal_cfg->'selected_items') > 0 THEN
                        DECLARE
                            v_item_elem JSONB;
                            v_rep_prod_id BIGINT;
                            v_included_prod_id BIGINT;
                            v_calc_charge NUMERIC;
                            v_included_prod_name TEXT;
                            v_elem_val TEXT;
                            v_sub_items_list TEXT[] := ARRAY[]::TEXT[];
                        BEGIN
                            FOR k IN 0..(jsonb_array_length(v_meal_cfg->'selected_items') - 1) LOOP
                                v_item_elem := v_meal_cfg->'selected_items'->k;
                                
                                IF v_item_elem->>'included_product_id' IS NOT NULL AND v_item_elem->>'upgrade_product_id' IS NOT NULL THEN
                                    v_included_prod_id := (v_item_elem->>'included_product_id')::BIGINT;
                                    v_rep_prod_id := (v_item_elem->>'upgrade_product_id')::BIGINT;
                                    
                                    IF v_rep_prod_id = v_included_prod_id THEN
                                        v_elem_val := v_item_elem->>'name';
                                    ELSE
                                        SELECT upgrade_price INTO v_calc_charge
                                        FROM public.product_upgrade_mapping
                                        WHERE base_product_id = v_included_prod_id AND upgrade_product_id = v_rep_prod_id AND is_active = TRUE
                                        LIMIT 1;
                                        
                                        v_calc_charge := COALESCE(v_calc_charge, 0.0);
                                        
                                        SELECT name INTO v_included_prod_name FROM public.products WHERE id = v_included_prod_id;
                                        v_elem_val := COALESCE(v_included_prod_name, 'Included') || ' → ' || (v_item_elem->>'name');
                                        IF v_calc_charge > 0 THEN
                                            v_elem_val := v_elem_val || ' (+₹' || v_calc_charge || ')';
                                        END IF;
                                    END IF;
                                 ELSE
                                    v_elem_val := v_item_elem->>'name';
                                 END IF;
                                 
                                 v_sub_items_list := array_append(v_sub_items_list, v_elem_val);
                            END LOOP;
                            
                            SELECT string_agg(s, ', ') INTO v_item_names FROM unnest(v_sub_items_list) s;
                        END;
                    END IF;
                    
                    IF v_item_names <> '' THEN
                        IF v_formatted_cfgs <> '' THEN
                            v_formatted_cfgs := v_formatted_cfgs || '; ';
                        END IF;
                        v_formatted_cfgs := v_formatted_cfgs || v_group_name || ': [' || v_item_names || ']';
                    END IF;
                END LOOP;
                v_addons_names := v_formatted_cfgs;
            END;
        ELSIF v_item_data->'addons' IS NOT NULL AND jsonb_array_length(v_item_data->'addons') > 0 THEN
            SELECT string_agg(name, ', ') INTO v_addons_names 
            FROM public.addons 
            WHERE id IN (
                SELECT (jsonb_array_elements(v_item_data->'addons')->>'id')::BIGINT
            );
        END IF;

        INSERT INTO public.order_items (
            order_id, product_id, product_name, product_image, 
            variant_name, addons, quantity, price, total
        ) VALUES (
            v_order_id, 
            (v_item_data->>'product_id')::BIGINT,
            (v_item_data->>'name'),
            (v_item_data->>'image'),
            v_variant_name,
            COALESCE(v_addons_names, ''),
            (v_item_data->>'quantity')::INTEGER,
            v_item_price,
            v_item_price * (v_item_data->>'quantity')::INTEGER
        ) RETURNING id INTO v_order_item_id;

        -- Insert selected upgrades into public.order_meal_upgrades
        IF v_item_data->'meal_configurations' IS NOT NULL AND jsonb_array_length(v_item_data->'meal_configurations') > 0 THEN
            DECLARE
                v_meal_cfg JSONB;
                v_item_elem JSONB;
                v_group_id BIGINT;
                v_rep_prod_id BIGINT;
                v_included_prod_id BIGINT;
                v_calc_charge NUMERIC := 0.0;
            BEGIN
                FOR j IN 0..(jsonb_array_length(v_item_data->'meal_configurations') - 1) LOOP
                    v_meal_cfg := v_item_data->'meal_configurations'->j;
                    v_group_id := (v_meal_cfg->>'group_id')::BIGINT;
                    
                    IF v_meal_cfg->'selected_items' IS NOT NULL THEN
                        FOR k IN 0..(jsonb_array_length(v_meal_cfg->'selected_items') - 1) LOOP
                            v_item_elem := v_meal_cfg->'selected_items'->k;
                            
                            IF v_item_elem->>'included_product_id' IS NOT NULL AND v_item_elem->>'upgrade_product_id' IS NOT NULL THEN
                                v_included_prod_id := (v_item_elem->>'included_product_id')::BIGINT;
                                v_rep_prod_id := (v_item_elem->>'upgrade_product_id')::BIGINT;
                                
                                IF v_included_prod_id <> v_rep_prod_id THEN
                                    SELECT upgrade_price INTO v_calc_charge
                                    FROM public.product_upgrade_mapping
                                    WHERE base_product_id = v_included_prod_id AND upgrade_product_id = v_rep_prod_id AND is_active = TRUE
                                    LIMIT 1;
                                    
                                    v_calc_charge := COALESCE(v_calc_charge, 0.0);
                                    
                                    INSERT INTO public.order_meal_upgrades (
                                        order_item_id, group_id, included_product_id, 
                                        upgrade_product_id, upgrade_charge
                                    ) VALUES (
                                        v_order_item_id, v_group_id, v_included_prod_id, 
                                        v_rep_prod_id, v_calc_charge
                                    );
                                END IF;
                            END IF;
                        END LOOP;
                    END IF;
                END LOOP;
            END;
        END IF;
    END LOOP;

    -- 10. Record Coupon Usage
    IF v_coupon_discount > 0 AND p_coupon_code IS NOT NULL THEN
        DECLARE
            v_coupon_id BIGINT;
        BEGIN
            SELECT id INTO v_coupon_id FROM public.coupons WHERE code = p_coupon_code LIMIT 1;
            IF v_coupon_id IS NOT NULL THEN
                INSERT INTO public.coupon_usage (coupon_id, user_id, order_id)
                VALUES (v_coupon_id, v_user.id, v_order_id);
            END IF;
        END;
    END IF;

    -- 11. Process Wallet coins deduction
    IF v_wallet_redeem_coins > 0 THEN
        UPDATE public.cheesy_wallets 
        SET available_coins = available_coins - v_wallet_redeem_coins,
            lifetime_redeemed = lifetime_redeemed + v_wallet_redeem_coins,
            updated_at = NOW()
        WHERE user_id = v_user.id;

        INSERT INTO public.cheesy_wallet_transactions (
            user_id, transaction_type, coins, rupee_value, 
            reference_type, reference_id, remarks
        ) VALUES (
            v_user.id, 'redeem', v_wallet_redeem_coins, v_wallet_redeem_rupees,
            'order', v_order_id::text, 'Redeemed on order #' || v_order_id
        );
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'order_id', v_order_id,
        'total', v_final_total,
        'subtotal', v_subtotal,
        'gst', v_gst,
        'delivery_fee', v_delivery_fee,
        'coupon_discount', v_coupon_discount,
        'wallet_discount', v_wallet_redeem_rupees
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.secure_create_order(
    p_items JSONB,
    p_delivery_mode TEXT,
    p_address TEXT,
    p_landmark TEXT,
    p_payment_method TEXT,
    p_coupon_code TEXT,
    p_use_wallet BOOLEAN,
    p_session_token TEXT,
    p_address_id BIGINT DEFAULT NULL::BIGINT,
    p_road_distance_km NUMERIC DEFAULT NULL::NUMERIC,
    p_estimated_time_minutes NUMERIC DEFAULT NULL::NUMERIC,
    p_route_geometry JSONB DEFAULT NULL::JSONB
)
RETURNS JSONB AS $$
DECLARE
    v_session RECORD;
    v_user RECORD;
    v_wallet RECORD;
    v_wallet_settings RECORD;
    v_coupon RECORD;
    v_offer RECORD;
    v_coupon_found BOOLEAN := FALSE;
    v_delivery_settings RECORD;
    v_slab RECORD;
    v_slab_matched BOOLEAN := FALSE;
    v_slab_charge NUMERIC := 0.0;
    v_slab_free_above NUMERIC;
    v_max_slab_limit NUMERIC := 10.0;
    v_subtotal NUMERIC := 0.0;
    v_gst NUMERIC := 0.0;
    v_delivery_fee NUMERIC := 0.0;
    v_coupon_discount NUMERIC := 0.0;
    v_wallet_redeem_coins INT := 0;
    v_wallet_redeem_rupees NUMERIC := 0.0;
    v_final_total NUMERIC := 0.0;
    v_order_id BIGINT;
    v_order_item_id BIGINT;
    v_items_count INT;
    v_item_data JSONB;
    v_product RECORD;
    v_item_price NUMERIC;
    v_variant_name TEXT;
    v_addons_names TEXT;
    v_addr_lat NUMERIC;
    v_addr_lng NUMERIC;
    v_addr_map_link TEXT;
    v_distance NUMERIC;
    v_store_lat NUMERIC := 27.795029;
    v_store_lng NUMERIC := 76.643329;
    v_init_payment_status TEXT;
    v_init_order_status TEXT;
    v_init_status TEXT;
    v_cust_name TEXT;
    v_cust_phone TEXT;
BEGIN
    -- 1. Validate Session Token
    SELECT * INTO v_session FROM public.active_sessions WHERE token = p_session_token AND expires_at > NOW() LIMIT 1;
    IF v_session IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid or expired session. Please login again.');
    END IF;

    SELECT * INTO v_user FROM public.users WHERE id = v_session.user_id LIMIT 1;
    IF v_user IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'User profile not found.');
    END IF;

    v_cust_name := COALESCE(v_user.full_name, v_user.name, 'Customer');
    v_cust_phone := COALESCE(v_user.mobile, v_user.phone, '');

    -- 2. Validate Items & Compute Subtotal accurately
    v_items_count := jsonb_array_length(p_items);
    IF v_items_count = 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'Order cart is empty.');
    END IF;

    FOR i IN 0..(v_items_count - 1) LOOP
        v_item_data := p_items->i;
        SELECT * INTO v_product FROM public.products WHERE id = (v_item_data->>'product_id')::BIGINT LIMIT 1;
        IF v_product IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error', 'Product not found: ' || (v_item_data->>'name'));
        END IF;

        v_item_price := (v_item_data->>'price')::NUMERIC;
        v_subtotal := v_subtotal + (v_item_price * (v_item_data->>'quantity')::INTEGER);
    END LOOP;

    -- 3. Calculate Delivery Fee & Location Details (Note: column in addresses table is 'map_link')
    IF p_address_id IS NOT NULL THEN
        SELECT latitude, longitude, map_link INTO v_addr_lat, v_addr_lng, v_addr_map_link
        FROM public.addresses WHERE id = p_address_id LIMIT 1;
    END IF;

    IF p_delivery_mode = 'delivery' THEN
        IF p_road_distance_km IS NOT NULL THEN
            v_distance := p_road_distance_km;
        ELSIF v_addr_lat IS NOT NULL AND v_addr_lng IS NOT NULL THEN
            v_distance := public.calculate_distance_km(v_store_lat, v_store_lng, v_addr_lat, v_addr_lng);
        END IF;

        SELECT * INTO v_delivery_settings FROM public.delivery_settings ORDER BY id LIMIT 1;

        IF v_distance IS NULL THEN
            -- Same as CheckoutPage.jsx's "calculatedDistance === null" branch:
            -- flat free-above threshold vs the configured flat delivery charge.
            IF v_delivery_settings IS NOT NULL AND v_subtotal >= COALESCE(v_delivery_settings.free_delivery_above, 299) THEN
                v_delivery_fee := 0.0;
            ELSE
                v_delivery_fee := COALESCE(v_delivery_settings.delivery_charge, 40.0);
            END IF;
        ELSE
            -- Same as CheckoutPage.jsx's distance-slab branch. Reuses the
            -- jsonb_to_recordset(...) slab pattern already proven elsewhere
            -- in this codebase (e.g. payment_recovery_system.sql).
            v_slab_matched := FALSE;
            v_slab_free_above := NULL;
            v_slab_charge := 0.0;
            v_max_slab_limit := 10.0;

            IF v_delivery_settings IS NOT NULL AND v_delivery_settings.distance_slabs IS NOT NULL THEN
                FOR v_slab IN SELECT * FROM jsonb_to_recordset(v_delivery_settings.distance_slabs) AS (min NUMERIC, max NUMERIC, charge NUMERIC, free_above NUMERIC) LOOP
                    IF v_slab.max IS NOT NULL AND v_slab.max > v_max_slab_limit THEN
                        v_max_slab_limit := v_slab.max;
                    END IF;
                    IF (NOT v_slab_matched) AND v_distance >= v_slab.min AND v_distance < v_slab.max THEN
                        v_slab_charge := COALESCE(v_slab.charge, 0.0);
                        v_slab_free_above := v_slab.free_above;
                        v_slab_matched := TRUE;
                    END IF;
                END LOOP;
            END IF;

            IF (NOT v_slab_matched) OR v_distance > v_max_slab_limit THEN
                -- Out of delivery range. (The frontend already blocks placing
                -- such an order with a toast before reaching this RPC; this
                -- just mirrors its fee value defensively.)
                v_delivery_fee := 0.0;
            ELSIF v_slab_free_above IS NOT NULL AND v_subtotal >= v_slab_free_above THEN
                v_delivery_fee := 0.0;
            ELSE
                v_delivery_fee := v_slab_charge;
            END IF;
        END IF;
    ELSE
        v_delivery_fee := 0.0;
    END IF;

    -- 4. Calculate GST (5%)
    v_gst := ROUND(v_subtotal * 0.05, 2);

    -- 5. Validate Coupon Code (public.coupons, falling back to the legacy
    --    public.offers table -- identical fallback to secure_validate_coupon()
    --    so a coupon accepted at checkout is never silently dropped here).
    IF p_coupon_code IS NOT NULL AND p_coupon_code <> '' THEN
        v_coupon_found := FALSE;

        SELECT * INTO v_coupon FROM public.coupons WHERE code = p_coupon_code AND active = TRUE LIMIT 1;
        IF FOUND THEN
            v_coupon_found := TRUE;
        ELSE
            SELECT * INTO v_offer FROM public.offers WHERE code = p_coupon_code AND active = TRUE LIMIT 1;
            IF FOUND THEN
                v_coupon.id := v_offer.id;
                v_coupon.code := v_offer.code;
                v_coupon.discount_type := v_offer.discount_type;
                v_coupon.discount_value := COALESCE(v_offer.discount_value, 0.0);
                v_coupon.max_discount := v_offer.max_discount;
                v_coupon.min_order := COALESCE(v_offer.min_order, 0.0);
                v_coupon_found := TRUE;
            END IF;
        END IF;

        IF v_coupon_found THEN
            IF v_subtotal >= COALESCE(v_coupon.min_order, 0.0) THEN
                IF v_coupon.discount_type = 'percentage' THEN
                    v_coupon_discount := ROUND(v_subtotal * (v_coupon.discount_value / 100.0), 2);
                    IF v_coupon.max_discount IS NOT NULL AND v_coupon_discount > v_coupon.max_discount THEN
                        v_coupon_discount := v_coupon.max_discount;
                    END IF;
                ELSIF v_coupon.discount_type = 'flat' THEN
                    v_coupon_discount := v_coupon.discount_value;
                END IF;
            END IF;
        END IF;
    END IF;

    -- 6. Validate & Atomically Deduct Wallet Balance (SELECT ... FOR UPDATE)
    IF p_use_wallet = TRUE THEN
        SELECT * INTO v_wallet
        FROM public.cheesy_wallets
        WHERE user_id = v_user.id AND wallet_status = 'active'
        FOR UPDATE;

        SELECT * INTO v_wallet_settings
        FROM public.cheesy_wallet_settings
        WHERE id = 1 LIMIT 1;

        IF v_wallet IS NOT NULL AND v_wallet_settings IS NOT NULL AND v_wallet.available_coins > 0 THEN
            IF v_subtotal >= COALESCE(v_wallet_settings.min_order_value, 0) THEN
                DECLARE
                    v_max_rupee_discount NUMERIC;
                    v_coins_needed INT;
                    v_ratio NUMERIC := 1.0;
                BEGIN
                    v_ratio := COALESCE(v_wallet_settings.coin_ratio_rupees / NULLIF(v_wallet_settings.coin_ratio_coins, 0), 1.0);
                    v_max_rupee_discount := ROUND(v_subtotal * (COALESCE(v_wallet_settings.max_redeem_percent, 50) / 100.0), 2);
                    v_coins_needed := CEIL(v_max_rupee_discount / v_ratio);

                    v_wallet_redeem_coins := LEAST(v_wallet.available_coins, v_coins_needed);
                    v_wallet_redeem_rupees := ROUND(v_wallet_redeem_coins * v_ratio, 2);
                END;
            END IF;
        END IF;
    END IF;

    -- 7. Calculate Final Total
    v_final_total := v_subtotal + v_gst + v_delivery_fee - v_coupon_discount - v_wallet_redeem_rupees;
    IF v_final_total < 0 THEN
        v_final_total := 0.0;
    END IF;

    -- Determine Initial Status values
    IF p_payment_method = 'COD' THEN
        v_init_payment_status := 'PAYMENT_PENDING';
        v_init_order_status := 'CONFIRMED';
        v_init_status := 'Pending';
    ELSIF v_final_total <= 0 THEN
        v_init_payment_status := 'SUCCESS';
        v_init_order_status := 'CONFIRMED';
        v_init_status := 'Pending';
    ELSE
        v_init_payment_status := 'PAYMENT_PENDING';
        v_init_order_status := 'PAYMENT_PENDING';
        v_init_status := 'PAYMENT_PENDING';
    END IF;

    -- 8. Insert Order Record securely
    INSERT INTO public.orders (
        user_id, customer_name, phone, address, landmark,
        payment_method, payment_status, order_status, subtotal, gst, delivery_fee,
        total, status, delivery_mode, coupon_code, coupon_discount,
        coins_redeemed, coins_earned, order_source,
        latitude, longitude, distance_km, google_map_link,
        road_distance_km, estimated_time_minutes, route_geometry,
        payment_gateway, payment_attempt, payment_verified, auto_retry_enabled,
        wallet_redemption_status, wallet_redemption_updated_at
    ) VALUES (
        v_user.id, v_cust_name, v_cust_phone, p_address, p_landmark,
        p_payment_method, v_init_payment_status, v_init_order_status, v_subtotal, v_gst, v_delivery_fee,
        v_final_total, v_init_status, p_delivery_mode, p_coupon_code, v_coupon_discount,
        v_wallet_redeem_coins, 0, 'online',
        v_addr_lat, v_addr_lng, v_distance, v_addr_map_link,
        p_road_distance_km, p_estimated_time_minutes, p_route_geometry,
        CASE WHEN p_payment_method = 'COD' THEN 'COD' ELSE 'Razorpay' END, 0, FALSE, TRUE,
        CASE WHEN v_wallet_redeem_coins > 0 THEN 'COMPLETED' ELSE 'NONE' END, NOW()
    ) RETURNING id INTO v_order_id;

    -- 9. Atomically Deduct Wallet Balance & Log Transaction inside the same DB Transaction
    IF v_wallet_redeem_coins > 0 THEN
        UPDATE public.cheesy_wallets
        SET available_coins = GREATEST(0, available_coins - v_wallet_redeem_coins),
            lifetime_redeemed = lifetime_redeemed + v_wallet_redeem_coins,
            updated_at = NOW()
        WHERE user_id = v_user.id;

        INSERT INTO public.cheesy_wallet_transactions (
            user_id, transaction_type, coins, rupee_value, reference_type, reference_id, remarks
        ) VALUES (
            v_user.id, 'redeem', -v_wallet_redeem_coins, -v_wallet_redeem_rupees, 'order', v_order_id::text, 'Redeemed on Order #' || v_order_id
        );
    END IF;

    -- Update last_used_at timestamp on saved address if relevant
    IF p_address_id IS NOT NULL THEN
        UPDATE public.addresses SET last_used_at = NOW() WHERE id = p_address_id;
    END IF;

    -- 10. Insert Order Items Records
    FOR i IN 0..(v_items_count - 1) LOOP
        v_item_data := p_items->i;
        v_item_price := (v_item_data->>'price')::NUMERIC;
        v_variant_name := COALESCE(v_item_data->'variant'->>'name', '');
        v_addons_names := '';

        IF jsonb_typeof(v_item_data->'addons') = 'array' AND jsonb_array_length(v_item_data->'addons') > 0 THEN
            DECLARE
                v_addon_names_list TEXT[] := ARRAY[]::TEXT[];
            BEGIN
                FOR j IN 0..(jsonb_array_length(v_item_data->'addons') - 1) LOOP
                    v_addon_names_list := array_append(v_addon_names_list, (v_item_data->'addons'->j->>'name')::TEXT);
                END LOOP;
                v_addons_names := array_to_string(v_addon_names_list, ', ');
            END;
        END IF;

        INSERT INTO public.order_items (
            order_id, product_id, product_name, price, quantity, variant_name, addons
        ) VALUES (
            v_order_id,
            (v_item_data->>'product_id')::BIGINT,
            v_item_data->>'name',
            v_item_price,
            (v_item_data->>'quantity')::INTEGER,
            v_variant_name,
            CASE WHEN v_addons_names = '' THEN NULL ELSE v_addons_names END
        ) RETURNING id INTO v_order_item_id;
    END LOOP;

    RETURN jsonb_build_object(
        'success', true,
        'order_id', v_order_id,
        'total', v_final_total,
        'subtotal', v_subtotal,
        'gst', v_gst,
        'delivery_fee', v_delivery_fee,
        'coupon_discount', v_coupon_discount,
        'wallet_discount', v_wallet_redeem_rupees
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.secure_confirm_order_payment(
    p_order_id BIGINT,
    p_session_token TEXT,
    p_razorpay_payment_id TEXT,
    p_razorpay_order_id TEXT,
    p_signature TEXT,
    p_gateway TEXT DEFAULT 'Razorpay'
)
RETURNS JSONB AS $$
DECLARE
    v_session RECORD;
    v_order RECORD;
    v_user RECORD;
    v_attempt_count INT;
BEGIN
    SELECT * INTO v_session 
    FROM public.active_sessions 
    WHERE token = p_session_token AND expires_at > NOW() 
    LIMIT 1;

    IF v_session IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Session expired or invalid. Please log in again.');
    END IF;

    SELECT * INTO v_user 
    FROM public.users 
    WHERE id = v_session.user_id 
    LIMIT 1;

    IF v_user IS NULL OR v_user.status <> 'active' THEN
        RETURN jsonb_build_object('success', false, 'error', 'User account is suspended or invalid.');
    END IF;

    SELECT * INTO v_order 
    FROM public.orders 
    WHERE id = p_order_id 
    LIMIT 1;

    IF v_order IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Order not found.');
    END IF;

    IF v_order.user_id <> v_user.id AND v_user.role NOT IN ('super_admin', 'admin', 'manager') THEN
        RETURN jsonb_build_object('success', false, 'error', 'Unauthorized to update this order.');
    END IF;

    v_attempt_count := COALESCE(v_order.payment_attempt, 0);
    
    UPDATE public.orders SET
        payment_status = 'SUCCESS',
        order_status = 'CONFIRMED',
        status = 'CONFIRMED',
        payment_reference = p_razorpay_payment_id,
        payment_gateway = p_gateway,
        payment_verified = TRUE,
        verified_at = NOW(),
        razorpay_payment_id = p_razorpay_payment_id,
        razorpay_order_id = p_razorpay_order_id,
        auto_retry_enabled = FALSE
    WHERE id = p_order_id;

    INSERT INTO public.payment_transactions (
        order_id, gateway, payment_id, order_reference, signature, amount, status, response
    ) VALUES (
        p_order_id, p_gateway, p_razorpay_payment_id, p_razorpay_order_id, p_signature, v_order.total, 'SUCCESS', 
        jsonb_build_object('verified_via', 'secure_confirm_order_payment', 'attempt', v_attempt_count)
    );

    RETURN jsonb_build_object('success', true, 'order_id', p_order_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.secure_fail_order_payment(
    p_order_id BIGINT,
    p_session_token TEXT,
    p_gateway TEXT DEFAULT 'Razorpay',
    p_payment_id TEXT DEFAULT NULL,
    p_order_reference TEXT DEFAULT NULL,
    p_response JSONB DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_session RECORD;
    v_order RECORD;
    v_user RECORD;
    v_attempt_count INT;
BEGIN
    -- 1. Validate Session Token
    SELECT * INTO v_session 
    FROM public.active_sessions 
    WHERE token = p_session_token AND expires_at > NOW() 
    LIMIT 1;

    IF v_session IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Session expired or invalid.');
    END IF;

    -- Load User
    SELECT * INTO v_user 
    FROM public.users 
    WHERE id = v_session.user_id 
    LIMIT 1;

    IF v_user IS NULL OR v_user.status <> 'active' THEN
        RETURN jsonb_build_object('success', false, 'error', 'User account is suspended or invalid.');
    END IF;

    -- 2. Verify Order Exists
    SELECT * INTO v_order 
    FROM public.orders 
    WHERE id = p_order_id 
    LIMIT 1;

    IF v_order IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Order not found.');
    END IF;

    IF v_order.user_id <> v_user.id AND v_user.role NOT IN ('super_admin', 'admin', 'manager') THEN
        RETURN jsonb_build_object('success', false, 'error', 'Unauthorized to update this order.');
    END IF;

    v_attempt_count := COALESCE(v_order.payment_attempt, 1);

    -- Update order to FAILED / PAYMENT_FAILED
    UPDATE public.orders SET
        payment_status = 'FAILED',
        order_status = 'PAYMENT_FAILED',
        payment_attempt = v_attempt_count + 1 -- Increment attempt for next retry
    WHERE id = p_order_id;

    -- Record transaction
    INSERT INTO public.payment_transactions (
        order_id, gateway, payment_id, order_reference, signature, amount, status, response
    ) VALUES (
        p_order_id, p_gateway, p_payment_id, p_order_reference, NULL, v_order.total, 'FAILED', 
        COALESCE(p_response, jsonb_build_object('event', 'payment_cancelled_or_dismissed', 'attempt', v_attempt_count))
    );

    RETURN jsonb_build_object('success', true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.secure_manual_verify_payment(
    p_order_id BIGINT,
    p_session_token TEXT,
    p_action TEXT,
    p_note TEXT,
    p_force BOOLEAN DEFAULT FALSE,
    p_reason TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_session RECORD;
    v_order RECORD;
    v_user RECORD;
    v_old_payment_status TEXT;
    v_old_order_status TEXT;
    v_new_payment_status TEXT;
    v_new_order_status TEXT;
    v_new_status TEXT;
    v_log_note TEXT;
BEGIN
    SELECT * INTO v_session 
    FROM public.active_sessions 
    WHERE token = p_session_token AND expires_at > NOW() 
    LIMIT 1;

    IF v_session IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Session expired or invalid. Please log in again.');
    END IF;

    SELECT * INTO v_user 
    FROM public.users 
    WHERE id = v_session.user_id 
    LIMIT 1;

    IF v_user IS NULL OR v_user.status <> 'active' THEN
        RETURN jsonb_build_object('success', false, 'error', 'User account is suspended or invalid.');
    END IF;

    IF v_user.role NOT IN ('super_admin', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'Access Denied: Only Admins can manually verify payments.');
    END IF;

    SELECT * INTO v_order 
    FROM public.orders 
    WHERE id = p_order_id 
    LIMIT 1;

    IF v_order IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Order not found.');
    END IF;

    v_old_payment_status := v_order.payment_status;
    v_old_order_status := v_order.order_status;

    IF v_old_payment_status = 'SUCCESS' THEN
        IF NOT p_force THEN
            RETURN jsonb_build_object('success', false, 'error', 'Order is already marked as SUCCESS. Double verification blocked.');
        END IF;

        IF v_user.role <> 'super_admin' THEN
            RETURN jsonb_build_object('success', false, 'error', 'Access Denied: Only Super Admins can force verify payments.');
        END IF;

        IF p_reason IS NULL OR TRIM(p_reason) = '' THEN
            RETURN jsonb_build_object('success', false, 'error', 'Force verification requires a reason.');
        END IF;
    END IF;

    IF p_action = 'APPROVE' THEN
        v_new_payment_status := 'SUCCESS';
        v_new_order_status := 'CONFIRMED';
        v_new_status := 'CONFIRMED';
    ELSIF p_action = 'REJECT' THEN
        v_new_payment_status := 'FAILED';
        v_new_order_status := 'CANCELLED';
        v_new_status := 'CANCELLED';
    ELSE
        RETURN jsonb_build_object('success', false, 'error', 'Invalid verification action.');
    END IF;

    UPDATE public.orders SET
        payment_status = v_new_payment_status,
        order_status = v_new_order_status,
        status = v_new_status,
        payment_verified = TRUE,
        verified_at = NOW(),
        verified_by = v_user.id,
        verification_method = 'MANUAL',
        verification_note = p_note
    WHERE id = p_order_id;

    IF p_force THEN
        v_log_note := '[FORCE VERIFY REASON: ' || p_reason || '] ' || p_note;
    ELSE
        v_log_note := p_note;
    END IF;

    INSERT INTO public.payment_verification_logs (
        order_id, old_payment_status, new_payment_status,
        old_order_status, new_order_status, verified_by,
        verification_method, note
    ) VALUES (
        p_order_id, v_old_payment_status, v_new_payment_status,
        v_old_order_status, v_new_order_status, v_user.id,
        'MANUAL', v_log_note
    );

    INSERT INTO public.system_audit_logs (
        user_name, user_role, action, device, details
    ) VALUES (
        v_user.full_name, v_user.role, 'manual_verify_payment', v_session.device,
        jsonb_build_object(
            'order_id', p_order_id,
            'action', p_action,
            'old_payment_status', v_old_payment_status,
            'new_payment_status', v_new_payment_status,
            'force', p_force,
            'force_reason', p_reason,
            'note', p_note
        )
    );

    RETURN jsonb_build_object('success', true, 'order_id', p_order_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.sync_order_statuses()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.status IS NULL AND NEW.order_status IS NOT NULL THEN
            NEW.status := UPPER(NEW.order_status);
        ELSIF NEW.order_status IS NULL AND NEW.status IS NOT NULL THEN
            NEW.order_status := UPPER(NEW.status);
        ELSIF NEW.status IS NOT NULL OR NEW.order_status IS NOT NULL THEN
            NEW.status := UPPER(COALESCE(NEW.status, NEW.order_status));
            NEW.order_status := NEW.status;
        END IF;
    ELSIF TG_OP = 'UPDATE' THEN
        IF NEW.status IS DISTINCT FROM OLD.status THEN
            NEW.status := UPPER(NEW.status);
            NEW.order_status := NEW.status;
        ELSIF NEW.order_status IS DISTINCT FROM OLD.order_status THEN
            NEW.order_status := UPPER(NEW.order_status);
            NEW.status := NEW.order_status;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.secure_increment_payment_attempt(
    p_order_id BIGINT,
    p_session_token TEXT,
    p_next_retry_seconds INT
)
RETURNS JSONB AS $$
DECLARE
    v_session RECORD;
    v_order RECORD;
    v_user RECORD;
    v_new_attempt INT;
    v_next_time TIMESTAMP WITH TIME ZONE;
BEGIN
    SELECT * INTO v_session 
    FROM public.active_sessions 
    WHERE token = p_session_token AND expires_at > NOW() 
    LIMIT 1;

    IF v_session IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Session expired or invalid.');
    END IF;

    SELECT * INTO v_user 
    FROM public.users 
    WHERE id = v_session.user_id 
    LIMIT 1;

    IF v_user IS NULL OR v_user.status <> 'active' THEN
        RETURN jsonb_build_object('success', false, 'error', 'User account is suspended or invalid.');
    END IF;

    SELECT * INTO v_order 
    FROM public.orders 
    WHERE id = p_order_id 
    LIMIT 1;

    IF v_order IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Order not found.');
    END IF;

    IF v_order.user_id <> v_user.id THEN
        RETURN jsonb_build_object('success', false, 'error', 'Unauthorized.');
    END IF;

    v_new_attempt := COALESCE(v_order.payment_attempt, 0) + 1;
    IF p_next_retry_seconds IS NOT NULL THEN
        v_next_time := NOW() + (p_next_retry_seconds || ' seconds')::INTERVAL;
    ELSE
        v_next_time := NULL;
    END IF;

    UPDATE public.orders SET
        payment_attempt = v_new_attempt,
        last_retry_at = NOW(),
        next_retry_at = v_next_time,
        auto_retry_enabled = CASE WHEN v_new_attempt >= 4 THEN FALSE ELSE TRUE END
    WHERE id = p_order_id;

    RETURN jsonb_build_object('success', true, 'new_attempt', v_new_attempt);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.secure_initiate_retry_payment(
    p_order_id BIGINT,
    p_session_token TEXT
)
RETURNS JSONB AS $$
DECLARE
    v_session RECORD;
    v_order RECORD;
    v_user RECORD;
BEGIN
    SELECT * INTO v_session 
    FROM public.active_sessions 
    WHERE token = p_session_token AND expires_at > NOW() 
    LIMIT 1;

    IF v_session IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Session expired or invalid.');
    END IF;

    SELECT * INTO v_user 
    FROM public.users 
    WHERE id = v_session.user_id 
    LIMIT 1;

    IF v_user IS NULL OR v_user.status <> 'active' THEN
        RETURN jsonb_build_object('success', false, 'error', 'User account is suspended or invalid.');
    END IF;

    SELECT * INTO v_order 
    FROM public.orders 
    WHERE id = p_order_id 
    LIMIT 1;

    IF v_order IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Order not found.');
    END IF;

    IF v_order.user_id <> v_user.id THEN
        RETURN jsonb_build_object('success', false, 'error', 'Unauthorized.');
    END IF;

    IF COALESCE(v_order.payment_verified, FALSE) = TRUE OR v_order.payment_status = 'SUCCESS' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Payment already verified.');
    END IF;

    UPDATE public.orders SET
        payment_status = 'PAYMENT_PENDING',
        order_status = 'PAYMENT_PENDING',
        status = 'PAYMENT_PENDING',
        payment_attempt = 0,
        auto_retry_enabled = TRUE,
        last_retry_at = NULL,
        next_retry_at = NULL
    WHERE id = p_order_id;

    RETURN jsonb_build_object('success', true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.secure_cancel_pending_payment_order(
    p_order_id BIGINT,
    p_session_token TEXT
)
RETURNS JSONB AS $$
DECLARE
    v_session RECORD;
    v_order RECORD;
    v_user RECORD;
BEGIN
    SELECT * INTO v_session 
    FROM public.active_sessions 
    WHERE token = p_session_token AND expires_at > NOW() 
    LIMIT 1;

    IF v_session IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Session expired or invalid.');
    END IF;

    SELECT * INTO v_user 
    FROM public.users 
    WHERE id = v_session.user_id 
    LIMIT 1;

    IF v_user IS NULL OR v_user.status <> 'active' THEN
        RETURN jsonb_build_object('success', false, 'error', 'User account is suspended or invalid.');
    END IF;

    SELECT * INTO v_order 
    FROM public.orders 
    WHERE id = p_order_id 
    LIMIT 1;

    IF v_order IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Order not found.');
    END IF;

    IF v_order.user_id <> v_user.id THEN
        RETURN jsonb_build_object('success', false, 'error', 'Unauthorized.');
    END IF;

    -- Cancel Order allowed ONLY IF payment_verified = false and payment_status != SUCCESS
    IF COALESCE(v_order.payment_verified, FALSE) = TRUE OR v_order.payment_status = 'SUCCESS' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Cannot cancel a verified or successful payment order.');
    END IF;

    UPDATE public.orders SET
        status = 'CANCELLED',
        order_status = 'CANCELLED',
        auto_retry_enabled = FALSE
    WHERE id = p_order_id;

    RETURN jsonb_build_object('success', true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.generate_supplier_code()
RETURNS TRIGGER AS $$
DECLARE
    seq_id INTEGER;
BEGIN
    IF NEW.supplier_code IS NULL OR NEW.supplier_code = '' THEN
        SELECT COALESCE(MAX(id), 0) + 1 INTO seq_id FROM public.suppliers;
        NEW.supplier_code := 'SUP-' || LPAD(seq_id::text, 4, '0');
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.enforce_finalized_po_immutability()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.status = 'Approved' THEN
        -- Allow transition to Cancelled or Received
        IF NEW.status IS DISTINCT FROM OLD.status AND NEW.status IN ('Cancelled', 'Received', 'Closed') THEN
            -- Validate that other details are not altered
            IF NEW.po_code IS DISTINCT FROM OLD.po_code OR
               NEW.supplier_id IS DISTINCT FROM OLD.supplier_id OR
               NEW.amount IS DISTINCT FROM OLD.amount OR
               NEW.expected_delivery IS DISTINCT FROM OLD.expected_delivery OR
               NEW.source_pr_code IS DISTINCT FROM OLD.source_pr_code THEN
                RAISE EXCEPTION 'Cannot modify core details of a finalized Purchase Order' USING ERRCODE = 'P0001';
            END IF;
        ELSE
            RAISE EXCEPTION 'Finalized Purchase Order is immutable and cannot be updated' USING ERRCODE = 'P0001';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.enforce_po_items_immutability()
RETURNS TRIGGER AS $$
DECLARE
    v_status TEXT;
BEGIN
    SELECT status INTO v_status FROM public.purchase_orders WHERE id = COALESCE(NEW.po_id, OLD.po_id);
    IF v_status = 'Approved' THEN
        RAISE EXCEPTION 'Line items of a finalized Purchase Order cannot be modified' USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.convert_units(
    p_ingredient_id BIGINT,
    p_qty NUMERIC,
    p_from_unit TEXT,
    p_to_unit TEXT
) RETURNS NUMERIC AS $$
DECLARE
    v_base_unit TEXT;
    v_conv_factor NUMERIC := 1;
    v_result NUMERIC;
BEGIN
    SELECT base_unit INTO v_base_unit FROM public.ingredient_master WHERE id = p_ingredient_id;
    
    -- Normalize units to lowercase
    IF LOWER(p_from_unit) = LOWER(p_to_unit) THEN
        RETURN p_qty;
    END IF;

    -- Weight conversions
    IF LOWER(p_from_unit) = 'kg' AND LOWER(p_to_unit) = 'gram' THEN
        RETURN p_qty * 1000;
    ELSIF LOWER(p_from_unit) = 'gram' AND LOWER(p_to_unit) = 'kg' THEN
        RETURN p_qty / 1000;
    END IF;

    -- Volume conversions
    IF LOWER(p_from_unit) = 'litre' AND LOWER(p_to_unit) = 'ml' THEN
        RETURN p_qty * 1000;
    ELSIF LOWER(p_from_unit) = 'ml' AND LOWER(p_to_unit) = 'litre' THEN
        RETURN p_qty / 1000;
    END IF;

    -- Count conversions
    IF LOWER(p_from_unit) = 'dozen' AND LOWER(p_to_unit) = 'piece' THEN
        RETURN p_qty * 12;
    ELSIF LOWER(p_from_unit) = 'piece' AND LOWER(p_to_unit) = 'dozen' THEN
        RETURN p_qty / 12;
    END IF;

    -- Search packaging configuration
    SELECT auto_conversion INTO v_conv_factor 
    FROM public.ingredient_packaging 
    WHERE ingredient_id = p_ingredient_id AND LOWER(purchase_unit) = LOWER(p_from_unit) 
    LIMIT 1;

    IF v_conv_factor IS NOT NULL AND LOWER(p_to_unit) = LOWER(v_base_unit) THEN
        RETURN p_qty * v_conv_factor;
    ELSIF v_conv_factor IS NOT NULL AND LOWER(p_from_unit) = LOWER(v_base_unit) THEN
        RETURN p_qty / v_conv_factor;
    END IF;

    -- Return quantity as is if conversion not defined
    RETURN p_qty;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.recalculate_recipe_costs_for_ingredient(p_ingredient_id BIGINT)
RETURNS VOID AS $$
DECLARE
    r_version RECORD;
    v_raw_cost NUMERIC;
    v_total_cost NUMERIC;
    v_selling_price NUMERIC;
    v_food_cost_pct NUMERIC;
    v_contrib_margin NUMERIC;
    v_gross_margin NUMERIC;
BEGIN
    FOR r_version IN 
        SELECT DISTINCT rv.*, rm.menu_item_id
        FROM public.recipe_versions rv
        JOIN public.recipe_master rm ON rv.recipe_master_id = rm.id
        JOIN public.recipe_items ri ON ri.recipe_version_id = rv.id
        WHERE ri.ingredient_id = p_ingredient_id
    LOOP
        -- Calculate raw ingredient cost in base units
        SELECT COALESCE(SUM(
            (ri.quantity * (1 + COALESCE(ri.waste_pct, 0) / 100)) / (COALESCE(ri.yield_pct, 100) / 100) * COALESCE(im.avg_cost, 0)
        ), 0) INTO v_raw_cost
        FROM public.recipe_items ri
        JOIN public.ingredient_master im ON ri.ingredient_id = im.id
        WHERE ri.recipe_version_id = r_version.id;

        v_total_cost := v_raw_cost + 
                        COALESCE(r_version.packaging_cost, 0) + 
                        COALESCE(r_version.labour_cost, 0) + 
                        COALESCE(r_version.gas_cost, 0) + 
                        COALESCE(r_version.electricity_cost, 0) + 
                        COALESCE(r_version.overhead_cost, 0) + 
                        COALESCE(r_version.platform_cost, 0);

        -- Fetch menu item selling price
        SELECT COALESCE(price, 0) INTO v_selling_price FROM public.products WHERE id = r_version.menu_item_id;

        IF v_selling_price > 0 THEN
            v_food_cost_pct := (v_raw_cost / v_selling_price) * 100;
        ELSE
            v_food_cost_pct := 0;
        END IF;

        v_contrib_margin := v_selling_price - v_total_cost;
        v_gross_margin := v_selling_price - v_raw_cost - COALESCE(r_version.packaging_cost, 0);

        -- Update cost variables
        UPDATE public.recipe_versions SET
            raw_ingredient_cost = v_raw_cost,
            total_cost = v_total_cost,
            food_cost_pct = v_food_cost_pct,
            contribution_margin = v_contrib_margin,
            gross_margin = v_gross_margin,
            updated_at = now()
        WHERE id = r_version.id;

    END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.check_and_trigger_reorder(p_ingredient_id BIGINT)
RETURNS VOID AS $$
DECLARE
    v_avail NUMERIC;
    v_reorder NUMERIC;
    v_max NUMERIC;
    v_ing_name TEXT;
    v_ing_sku TEXT;
    v_avg_cost NUMERIC;
    v_pending_pr_count INTEGER;
    v_pr_code TEXT;
    v_new_pr_id BIGINT;
    v_reorder_qty NUMERIC;
BEGIN
    -- Check available stock
    SELECT COALESCE(available_quantity, 0), COALESCE(reorder_level, 0), COALESCE(maximum_stock, 100)
    INTO v_avail, v_reorder, v_max
    FROM public.stock_master
    WHERE ingredient_id = p_ingredient_id;

    IF v_avail <= v_reorder THEN
        SELECT name, sku, COALESCE(avg_cost, 0) INTO v_ing_name, v_ing_sku, v_avg_cost
        FROM public.ingredient_master
        WHERE id = p_ingredient_id;

        -- Check if a pending PR already covers this ingredient
        SELECT COUNT(*) INTO v_pending_pr_count
        FROM public.purchase_requisitions pr
        JOIN public.purchase_requisition_items pri ON pri.pr_id = pr.id
        WHERE pri.ingredient_id = p_ingredient_id AND pr.status IN ('Draft', 'Submitted', 'Under Review');

        IF v_pending_pr_count = 0 THEN
            v_pr_code := 'PR-AUTO-' || TO_CHAR(now(), 'YYYYMMDD') || '-' || LPAD(p_ingredient_id::text, 4, '0');
            v_reorder_qty := v_max - v_avail;
            
            IF v_reorder_qty > 0 THEN
                -- Insert requisition header
                INSERT INTO public.purchase_requisitions (
                    pr_code,
                    requested_by,
                    department,
                    warehouse,
                    priority,
                    remarks,
                    status
                ) VALUES (
                    v_pr_code,
                    'System Reorder Engine',
                    'Kitchen',
                    'Central Warehouse',
                    'Medium',
                    'Automated stock level depletion alert trigger for ' || v_ing_name || ' (' || v_ing_sku || ').',
                    'Draft'
                ) RETURNING id INTO v_new_pr_id;

                -- Insert item list
                INSERT INTO public.purchase_requisition_items (
                    pr_id,
                    ingredient_id,
                    quantity,
                    estimated_cost,
                    remarks
                ) VALUES (
                    v_new_pr_id,
                    p_ingredient_id,
                    v_reorder_qty,
                    v_reorder_qty * v_ing_cost,
                    'Auto-generated by stock threshold check'
                );
            END IF;
        END IF;
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        NULL; -- fail-silent to prevent blocking main transactions
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.deduct_inventory_stock(
    p_ingredient_id BIGINT,
    p_qty NUMERIC, -- in base units
    p_warehouse_id BIGINT,
    p_doc_type TEXT,
    p_doc_num TEXT,
    p_created_by TEXT,
    p_remarks TEXT
) RETURNS VOID AS $$
DECLARE
    v_valuation TEXT;
    v_remaining NUMERIC := p_qty;
    v_batch RECORD;
    v_deduct NUMERIC;
    v_old_qty NUMERIC;
    v_new_qty NUMERIC;
    v_base_unit TEXT;
    v_sku TEXT;
    v_ing_name TEXT;
    v_avg_cost NUMERIC;
    v_allow_neg BOOLEAN;
    v_opening_stock NUMERIC;
    v_closing_stock NUMERIC;
    v_warehouse_name TEXT;
BEGIN
    -- Resolve ingredient metadata
    SELECT name, sku, base_unit, COALESCE(avg_cost, 0), COALESCE(allow_negative_stock, false)
    INTO v_ing_name, v_sku, v_base_unit, v_avg_cost, v_allow_neg
    FROM public.ingredient_master
    WHERE id = p_ingredient_id;

    -- Get current warehouse name
    SELECT name INTO v_warehouse_name FROM public.warehouses WHERE id = p_warehouse_id;

    -- Get total current stock in this warehouse
    SELECT COALESCE(quantity, 0) INTO v_opening_stock 
    FROM public.warehouse_stock 
    WHERE warehouse_id = p_warehouse_id AND ingredient_id = p_ingredient_id;

    -- Get valuation setting
    SELECT COALESCE(valuation_method, 'FIFO') INTO v_valuation FROM public.inventory_settings LIMIT 1;

    IF v_remaining <= 0 THEN
        RETURN;
    END IF;

    -- Process batch deduction
    FOR v_batch IN 
        SELECT * FROM public.ingredient_batches
        WHERE ingredient_id = p_ingredient_id 
          AND warehouse_id = p_warehouse_id 
          AND current_qty > 0
          -- FIFO uses mfg/creation date; FEFO uses expiry
          ORDER BY 
            CASE WHEN v_valuation = 'FEFO' THEN expiry_date END ASC,
            created_at ASC
    LOOP
        IF v_remaining <= 0 THEN
            EXIT;
        END IF;

        IF v_batch.current_qty >= v_remaining THEN
            v_deduct := v_remaining;
            v_remaining := 0;
        ELSE
            v_deduct := v_batch.current_qty;
            v_remaining := v_remaining - v_deduct;
        END IF;

        -- Update batch quantity
        UPDATE public.ingredient_batches 
        SET current_qty = current_qty - v_deduct, updated_at = now() 
        WHERE id = v_batch.id;

        -- Update local warehouse stock quantity
        UPDATE public.warehouse_stock 
        SET quantity = quantity - v_deduct, updated_at = now() 
        WHERE warehouse_id = p_warehouse_id AND ingredient_id = p_ingredient_id;

        -- Update global available stock
        UPDATE public.stock_master 
        SET available_quantity = available_quantity - v_deduct 
        WHERE ingredient_id = p_ingredient_id;

        -- Log stock ledger log for this batch segment
        INSERT INTO public.stock_ledger (
            ingredient_id,
            document_type,
            document_number,
            reference_id,
            sku,
            warehouse,
            batch_number,
            lot_number,
            expiry_date,
            opening_stock,
            stock_out,
            closing_stock,
            unit,
            average_cost,
            current_cost,
            created_by,
            remarks
        ) VALUES (
            p_ingredient_id,
            p_doc_type,
            p_doc_num,
            v_batch.batch_number,
            v_sku,
            v_warehouse_name,
            v_batch.batch_number,
            v_batch.lot_number,
            v_batch.expiry_date,
            v_opening_stock,
            v_deduct,
            v_opening_stock - v_deduct,
            v_base_unit,
            v_avg_cost,
            v_batch.unit_cost,
            p_created_by,
            p_remarks || ' (Batch: ' || v_batch.batch_number || ')'
        );

        v_opening_stock := v_opening_stock - v_deduct;
    END LOOP;

    -- If there is shortage remaining
    IF v_remaining > 0 THEN
        IF v_allow_neg THEN
            -- Deduct negative remainder directly from local stock
            UPDATE public.warehouse_stock 
            SET quantity = quantity - v_remaining, updated_at = now()
            WHERE warehouse_id = p_warehouse_id AND ingredient_id = p_ingredient_id;

            -- Deduct negative remainder from global stock
            UPDATE public.stock_master 
            SET available_quantity = available_quantity - v_remaining
            WHERE ingredient_id = p_ingredient_id;

            -- Log shortage ledger entry
            INSERT INTO public.stock_ledger (
                ingredient_id,
                document_type,
                document_number,
                sku,
                warehouse,
                opening_stock,
                stock_out,
                closing_stock,
                unit,
                average_cost,
                current_cost,
                created_by,
                remarks
            ) VALUES (
                p_ingredient_id,
                p_doc_type,
                p_doc_num,
                v_sku,
                v_warehouse_name,
                v_opening_stock,
                v_remaining,
                v_opening_stock - v_remaining,
                v_base_unit,
                v_avg_cost,
                v_avg_cost,
                p_created_by,
                p_remarks || ' (Shortage - Negative Stock Allowed)'
            );
        ELSE
            -- Raise validation exception to abort
            RAISE EXCEPTION 'Validation Error: Insufficient stock for % in % (Shortage: % %)', 
                v_ing_name, v_warehouse_name, v_remaining, v_base_unit;
        END IF;
    END IF;

    -- Post-deduction checks
    PERFORM public.check_and_trigger_reorder(p_ingredient_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.process_grn_completion(p_grn_id BIGINT, p_warehouse_id BIGINT)
RETURNS VOID AS $$
DECLARE
    v_grn RECORD;
    r_item RECORD;
    v_grn_code TEXT;
    v_supplier_id BIGINT;
    v_received_by TEXT;
    v_net_accepted NUMERIC;
    v_base_unit TEXT;
    v_sku TEXT;
    v_old_global_stock NUMERIC;
    v_old_warehouse_stock NUMERIC;
    v_new_avg_cost NUMERIC;
    v_shelf_life INTEGER;
    v_batch_num TEXT;
    v_lot_num TEXT;
    v_expiry DATE;
    v_warehouse_name TEXT;
    
    -- Landed cost variables
    v_total_overhead NUMERIC := 0;
    v_total_items_value NUMERIC := 0;
    v_item_share NUMERIC := 0;
    v_landing_cost NUMERIC := 0;
    v_po_code TEXT := '';
BEGIN
    -- Fetch GRN details
    SELECT * INTO v_grn FROM public.grns WHERE id = p_grn_id;
    v_grn_code := v_grn.grn_code;
    v_supplier_id := v_grn.supplier_id;
    v_received_by := COALESCE(v_grn.received_by, 'Manish Kumar');

    -- Resolve PO code if linked
    IF v_grn.po_id IS NOT NULL THEN
        SELECT po_code INTO v_po_code FROM public.purchase_orders WHERE id = v_grn.po_id;
    END IF;

    -- Fetch warehouse details
    SELECT name INTO v_warehouse_name FROM public.warehouses WHERE id = p_warehouse_id;

    -- Calculate total landed overhead
    v_total_overhead := COALESCE(v_grn.freight_charge, 0) + 
                        COALESCE(v_grn.insurance_charge, 0) + 
                        COALESCE(v_grn.loading_charge, 0) + 
                        COALESCE(v_grn.packing_charge, 0) + 
                        COALESCE(v_grn.transport_charge, 0) + 
                        COALESCE(v_grn.other_charges, 0);

    -- Calculate total invoice item values
    SELECT COALESCE(SUM(quantity_received * unit_cost), 0) INTO v_total_items_value 
    FROM public.grn_items 
    WHERE grn_id = p_grn_id;

    FOR r_item IN 
        SELECT * FROM public.grn_items WHERE grn_id = p_grn_id
    LOOP
        v_net_accepted := COALESCE(r_item.quantity_received, 0) - COALESCE(r_item.quantity_rejected, 0);

        IF v_net_accepted > 0 THEN
            -- Landed cost distribution math
            IF v_total_items_value > 0 THEN
                v_item_share := ((r_item.quantity_received * r_item.unit_cost) / v_total_items_value) * v_total_overhead;
                v_landing_cost := r_item.unit_cost + (v_item_share / v_net_accepted);
            ELSE
                v_item_share := 0;
                v_landing_cost := r_item.unit_cost;
            END IF;

            -- Get ingredient configurations
            SELECT sku, base_unit, COALESCE(shelf_life, 30) 
            INTO v_sku, v_base_unit, v_shelf_life
            FROM public.ingredient_master
            WHERE id = r_item.ingredient_id;

            -- Calculate dates
            v_expiry := CURRENT_DATE + v_shelf_life;
            v_batch_num := 'BAT-' || v_grn_code || '-' || r_item.ingredient_id;
            v_lot_num := 'LOT-' || v_grn_code || '-' || r_item.ingredient_id;

            -- Get current global stock level
            SELECT COALESCE(available_quantity, 0) INTO v_old_global_stock
            FROM public.stock_master
            WHERE ingredient_id = r_item.ingredient_id;

            -- Get current local warehouse stock level
            SELECT COALESCE(quantity, 0) INTO v_old_warehouse_stock
            FROM public.warehouse_stock
            WHERE warehouse_id = p_warehouse_id AND ingredient_id = r_item.ingredient_id;

            -- Check if warehouse stock row exists, else insert
            IF NOT EXISTS (
                SELECT 1 FROM public.warehouse_stock 
                WHERE warehouse_id = p_warehouse_id AND ingredient_id = r_item.ingredient_id
            ) THEN
                INSERT INTO public.warehouse_stock (warehouse_id, ingredient_id, quantity)
                VALUES (p_warehouse_id, r_item.ingredient_id, 0);
                v_old_warehouse_stock := 0;
            END IF;

            -- Recalculate costs (Moving Average Engine based on Landing Costs)
            SELECT 
                CASE 
                    WHEN (v_old_global_stock + v_net_accepted) <= 0 THEN v_landing_cost
                    ELSE ((v_old_global_stock * COALESCE(im.avg_cost, 0)) + (v_net_accepted * v_landing_cost)) / (v_old_global_stock + v_net_accepted)
                END INTO v_new_avg_cost
            FROM public.ingredient_master im
            WHERE im.id = r_item.ingredient_id;

            -- Update ingredient cost stats
            UPDATE public.ingredient_master SET
                avg_cost = v_new_avg_cost,
                last_purchase_cost = v_landing_cost,
                updated_at = now()
            WHERE id = r_item.ingredient_id;

            -- Update local warehouse stock
            UPDATE public.warehouse_stock SET
                quantity = quantity + v_net_accepted,
                updated_at = now()
            WHERE warehouse_id = p_warehouse_id AND ingredient_id = r_item.ingredient_id;

            -- Update global available stock in stock_master
            UPDATE public.stock_master SET
                available_quantity = available_quantity + v_net_accepted,
                updated_at = now()
            WHERE ingredient_id = r_item.ingredient_id;

            -- Create Batch tracking record
            INSERT INTO public.ingredient_batches (
                batch_number,
                lot_number,
                ingredient_id,
                warehouse_id,
                supplier_id,
                grn_id,
                mfg_date,
                expiry_date,
                shelf_life_days,
                original_qty,
                current_qty,
                unit_cost,
                landing_cost
            ) VALUES (
                v_batch_num,
                v_lot_num,
                r_item.ingredient_id,
                p_warehouse_id,
                v_supplier_id,
                p_grn_id,
                CURRENT_DATE,
                v_expiry,
                v_shelf_life,
                v_net_accepted,
                v_net_accepted,
                r_item.unit_cost,
                v_landing_cost
            );

            -- Log transaction to permanent Stock Ledger
            INSERT INTO public.stock_ledger (
                ingredient_id,
                document_type,
                document_number,
                sku,
                warehouse,
                batch_number,
                lot_number,
                expiry_date,
                opening_stock,
                stock_in,
                closing_stock,
                unit,
                average_cost,
                current_cost,
                landing_cost,
                created_by,
                remarks
            ) VALUES (
                r_item.ingredient_id,
                'Purchase Receipt',
                v_grn_code,
                v_sku,
                v_warehouse_name,
                v_batch_num,
                v_lot_num,
                v_expiry,
                v_old_warehouse_stock,
                v_net_accepted,
                v_old_warehouse_stock + v_net_accepted,
                v_base_unit,
                v_new_avg_cost,
                r_item.unit_cost,
                v_landing_cost,
                v_received_by,
                'Automated Goods Receipt posting from GRN: ' || v_grn_code
            );

            -- Record Supplier Price History
            INSERT INTO public.supplier_price_history (
                supplier_id,
                ingredient_id,
                po_id,
                po_code,
                rate,
                gst_pct,
                freight,
                landing_cost
            ) VALUES (
                v_supplier_id,
                r_item.ingredient_id,
                v_grn.po_id,
                v_po_code,
                r_item.unit_cost,
                0, -- default GST
                v_item_share,
                v_landing_cost
            );

            -- Recalculate Recipe cost formulas using this ingredient
            PERFORM public.recalculate_recipe_costs_for_ingredient(r_item.ingredient_id);
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.process_pos_order_completed_stock()
RETURNS TRIGGER AS $$
DECLARE
    r_item RECORD;
    r_rec_item RECORD;
    v_kitchen_wh_id BIGINT;
    v_rec_ver_id BIGINT;
    v_total_deduct_qty NUMERIC;
BEGIN
    -- Check if transitioning to Completed and stock not already deducted
    IF NEW.status = 'Completed' AND (OLD.status IS NULL OR OLD.status != 'Completed') AND NEW.stock_deducted = false THEN
        -- Get Kitchen warehouse id
        SELECT id INTO v_kitchen_wh_id FROM public.warehouses WHERE code = 'WH-KITCHEN' LIMIT 1;
        IF v_kitchen_wh_id IS NULL THEN
            SELECT id INTO v_kitchen_wh_id FROM public.warehouses LIMIT 1;
        END IF;

        -- Loop through order items
        FOR r_item IN 
            SELECT id, product_name, quantity 
            FROM public.pos_order_items 
            WHERE order_id = NEW.id
        LOOP
            -- Find the active recipe version mapped to this product
            SELECT rv.id INTO v_rec_ver_id
            FROM public.recipe_versions rv
            JOIN public.recipe_master rm ON rv.recipe_master_id = rm.id
            JOIN public.products p ON rm.menu_item_id = p.id
            WHERE p.name = r_item.product_name AND rv.status = 'Approved'
            LIMIT 1;

            -- Fall back to latest version if no approved version
            IF v_rec_ver_id IS NULL THEN
                SELECT rv.id INTO v_rec_ver_id
                FROM public.recipe_versions rv
                JOIN public.recipe_master rm ON rv.recipe_master_id = rm.id
                JOIN public.products p ON rm.menu_item_id = p.id
                WHERE p.name = r_item.product_name
                ORDER BY rv.version_code DESC LIMIT 1;
            END IF;

            -- Deduct ingredients if recipe exists
            IF v_rec_ver_id IS NOT NULL THEN
                FOR r_rec_item IN 
                    SELECT ingredient_id, quantity, waste_pct, yield_pct 
                    FROM public.recipe_items 
                    WHERE recipe_version_id = v_rec_ver_id
                LOOP
                    v_total_deduct_qty := r_item.quantity * r_rec_item.quantity * 
                                          (1 + COALESCE(r_rec_item.waste_pct, 0) / 100) / 
                                          (COALESCE(r_rec_item.yield_pct, 100) / 100);

                    PERFORM public.deduct_inventory_stock(
                        r_rec_item.ingredient_id,
                        v_total_deduct_qty,
                        v_kitchen_wh_id,
                        'Sales',
                        NEW.id::text,
                        'POS Cashier',
                        'Dine-in POS order completion auto-deduction: ' || r_item.product_name
                    );
                END LOOP;
            END IF;
        END LOOP;

        NEW.stock_deducted := true;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.process_delivery_order_completed_stock()
RETURNS TRIGGER AS $$
DECLARE
    r_item RECORD;
    r_rec_item RECORD;
    v_outlet_wh_id BIGINT;
    v_rec_ver_id BIGINT;
    v_total_deduct_qty NUMERIC;
BEGIN
    -- Check if transitioning to Completed and stock not already deducted
    IF NEW.status = 'Completed' AND (OLD.status IS NULL OR OLD.status != 'Completed') AND NEW.stock_deducted = false THEN
        -- Get Outlet warehouse id
        SELECT id INTO v_outlet_wh_id FROM public.warehouses WHERE code = 'WH-OUTLET' LIMIT 1;
        IF v_outlet_wh_id IS NULL THEN
            SELECT id INTO v_outlet_wh_id FROM public.warehouses LIMIT 1;
        END IF;

        -- Loop through order items
        FOR r_item IN 
            SELECT p.name AS product_name, oi.quantity 
            FROM public.order_items oi
            JOIN public.products p ON oi.product_id = p.id
            WHERE oi.order_id = NEW.id
        LOOP
            -- Find the active recipe version mapped to this product
            SELECT rv.id INTO v_rec_ver_id
            FROM public.recipe_versions rv
            JOIN public.recipe_master rm ON rv.recipe_master_id = rm.id
            WHERE rm.menu_item_id = (SELECT id FROM public.products WHERE name = r_item.product_name LIMIT 1) 
              AND rv.status = 'Approved'
            LIMIT 1;

            -- Fall back to latest version if no approved version
            IF v_rec_ver_id IS NULL THEN
                SELECT rv.id INTO v_rec_ver_id
                FROM public.recipe_versions rv
                JOIN public.recipe_master rm ON rv.recipe_master_id = rm.id
                WHERE rm.menu_item_id = (SELECT id FROM public.products WHERE name = r_item.product_name LIMIT 1)
                ORDER BY rv.version_code DESC LIMIT 1;
            END IF;

            -- Deduct ingredients if recipe exists
            IF v_rec_ver_id IS NOT NULL THEN
                FOR r_rec_item IN 
                    SELECT ingredient_id, quantity, waste_pct, yield_pct 
                    FROM public.recipe_items 
                    WHERE recipe_version_id = v_rec_ver_id
                LOOP
                    v_total_deduct_qty := r_item.quantity * r_rec_item.quantity * 
                                          (1 + COALESCE(r_rec_item.waste_pct, 0) / 100) / 
                                          (COALESCE(r_rec_item.yield_pct, 100) / 100);

                    PERFORM public.deduct_inventory_stock(
                        r_rec_item.ingredient_id,
                        v_total_deduct_qty,
                        v_outlet_wh_id,
                        'Sales',
                        NEW.id::text,
                        'Online System',
                        'Delivery/Online order completion auto-deduction: ' || r_item.product_name
                    );
                END LOOP;
            END IF;
        END LOOP;

        NEW.stock_deducted := true;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.handle_pos_reservation_lifecycle()
RETURNS TRIGGER AS $$
DECLARE
    r_item RECORD;
    r_rec_item RECORD;
    v_kitchen_wh_id BIGINT;
    v_rec_ver_id BIGINT;
    v_qty NUMERIC;
    v_is_insert BOOLEAN := (TG_OP = 'INSERT');
    v_is_update BOOLEAN := (TG_OP = 'UPDATE');
    v_old_status TEXT := '';
    v_new_status TEXT := '';
BEGIN
    -- Get Kitchen warehouse id
    SELECT id INTO v_kitchen_wh_id FROM public.warehouses WHERE code = 'WH-KITCHEN' LIMIT 1;
    IF v_kitchen_wh_id IS NULL THEN
        SELECT id INTO v_kitchen_wh_id FROM public.warehouses LIMIT 1;
    END IF;

    IF v_is_update THEN
        v_old_status := OLD.status;
        v_new_status := NEW.status;
    ELSE
        v_new_status := NEW.status;
    END IF;

    -- CASE 1: Reservation Activated (Insert or Status transitions to Pending/Created/Paid)
    IF (v_is_insert AND v_new_status IN ('Pending', 'Created', 'Paid')) OR
       (v_is_update AND v_new_status IN ('Pending', 'Created', 'Paid') AND v_old_status NOT IN ('Pending', 'Created', 'Paid')) THEN
        
        FOR r_item IN SELECT id, product_name, quantity FROM public.pos_order_items WHERE order_id = NEW.id LOOP
            -- Get active recipe version
            SELECT rv.id INTO v_rec_ver_id
            FROM public.recipe_versions rv
            JOIN public.recipe_master rm ON rv.recipe_master_id = rm.id
            JOIN public.products p ON rm.menu_item_id = p.id
            WHERE p.name = r_item.product_name AND rv.status = 'Approved' LIMIT 1;

            IF v_rec_ver_id IS NOT NULL THEN
                FOR r_rec_item IN SELECT ingredient_id, quantity, waste_pct, yield_pct FROM public.recipe_items WHERE recipe_version_id = v_rec_ver_id LOOP
                    v_qty := r_item.quantity * r_rec_item.quantity * (1 + COALESCE(r_rec_item.waste_pct, 0) / 100) / (COALESCE(r_rec_item.yield_pct, 100) / 100);

                    -- Check/insert warehouse stock
                    IF NOT EXISTS (SELECT 1 FROM public.warehouse_stock WHERE warehouse_id = v_kitchen_wh_id AND ingredient_id = r_rec_item.ingredient_id) THEN
                        INSERT INTO public.warehouse_stock (warehouse_id, ingredient_id, quantity, reserved_quantity) VALUES (v_kitchen_wh_id, r_rec_item.ingredient_id, 0, 0);
                    END IF;

                    -- Increment reserved quantity local
                    UPDATE public.warehouse_stock SET reserved_quantity = reserved_quantity + v_qty 
                    WHERE warehouse_id = v_kitchen_wh_id AND ingredient_id = r_rec_item.ingredient_id;

                    -- Increment reserved quantity global
                    UPDATE public.stock_master SET reserved_quantity = reserved_quantity + v_qty 
                    WHERE ingredient_id = r_rec_item.ingredient_id;
                END LOOP;
            END IF;
        END LOOP;

    -- CASE 2: Reservation Released on Cancellation
    ELSIF v_is_update AND v_new_status = 'Cancelled' AND v_old_status IN ('Pending', 'Created', 'Paid') THEN
        
        FOR r_item IN SELECT id, product_name, quantity FROM public.pos_order_items WHERE order_id = NEW.id LOOP
            SELECT rv.id INTO v_rec_ver_id
            FROM public.recipe_versions rv
            JOIN public.recipe_master rm ON rv.recipe_master_id = rm.id
            JOIN public.products p ON rm.menu_item_id = p.id
            WHERE p.name = r_item.product_name AND rv.status = 'Approved' LIMIT 1;

            IF v_rec_ver_id IS NOT NULL THEN
                FOR r_rec_item IN SELECT ingredient_id, quantity, waste_pct, yield_pct FROM public.recipe_items WHERE recipe_version_id = v_rec_ver_id LOOP
                    v_qty := r_item.quantity * r_rec_item.quantity * (1 + COALESCE(r_rec_item.waste_pct, 0) / 100) / (COALESCE(r_rec_item.yield_pct, 100) / 100);

                    UPDATE public.warehouse_stock SET reserved_quantity = GREATEST(0, reserved_quantity - v_qty) 
                    WHERE warehouse_id = v_kitchen_wh_id AND ingredient_id = r_rec_item.ingredient_id;

                    UPDATE public.stock_master SET reserved_quantity = GREATEST(0, reserved_quantity - v_qty) 
                    WHERE ingredient_id = r_rec_item.ingredient_id;
                END LOOP;
            END IF;
        END LOOP;

    -- CASE 3: Reservation Released on Completion (Subtracts reservation, triggers actual stock deduction)
    ELSIF v_is_update AND v_new_status = 'Completed' AND v_old_status IN ('Pending', 'Created', 'Paid') THEN
        
        FOR r_item IN SELECT id, product_name, quantity FROM public.pos_order_items WHERE order_id = NEW.id LOOP
            SELECT rv.id INTO v_rec_ver_id
            FROM public.recipe_versions rv
            JOIN public.recipe_master rm ON rv.recipe_master_id = rm.id
            JOIN public.products p ON rm.menu_item_id = p.id
            WHERE p.name = r_item.product_name AND rv.status = 'Approved' LIMIT 1;

            IF v_rec_ver_id IS NOT NULL THEN
                FOR r_rec_item IN SELECT ingredient_id, quantity, waste_pct, yield_pct FROM public.recipe_items WHERE recipe_version_id = v_rec_ver_id LOOP
                    v_qty := r_item.quantity * r_rec_item.quantity * (1 + COALESCE(r_rec_item.waste_pct, 0) / 100) / (COALESCE(r_rec_item.yield_pct, 100) / 100);

                    UPDATE public.warehouse_stock SET reserved_quantity = GREATEST(0, reserved_quantity - v_qty) 
                    WHERE warehouse_id = v_kitchen_wh_id AND ingredient_id = r_rec_item.ingredient_id;

                    UPDATE public.stock_master SET reserved_quantity = GREATEST(0, reserved_quantity - v_qty) 
                    WHERE ingredient_id = r_rec_item.ingredient_id;
                END LOOP;
            END IF;
        END LOOP;

    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.handle_delivery_reservation_lifecycle()
RETURNS TRIGGER AS $$
DECLARE
    r_item RECORD;
    r_rec_item RECORD;
    v_outlet_wh_id BIGINT;
    v_rec_ver_id BIGINT;
    v_qty NUMERIC;
    v_is_insert BOOLEAN := (TG_OP = 'INSERT');
    v_is_update BOOLEAN := (TG_OP = 'UPDATE');
    v_old_status TEXT := '';
    v_new_status TEXT := '';
BEGIN
    -- Get Outlet warehouse id
    SELECT id INTO v_outlet_wh_id FROM public.warehouses WHERE code = 'WH-OUTLET' LIMIT 1;
    IF v_outlet_wh_id IS NULL THEN
        SELECT id INTO v_outlet_wh_id FROM public.warehouses LIMIT 1;
    END IF;

    IF v_is_update THEN
        v_old_status := OLD.status;
        v_new_status := NEW.status;
    ELSE
        v_new_status := NEW.status;
    END IF;

    -- CASE 1: Reservation Activated
    IF (v_is_insert AND v_new_status IN ('Pending', 'Created', 'Paid')) OR
       (v_is_update AND v_new_status IN ('Pending', 'Created', 'Paid') AND v_old_status NOT IN ('Pending', 'Created', 'Paid')) THEN
        
        FOR r_item IN SELECT product_id, quantity FROM public.order_items WHERE order_id = NEW.id LOOP
            SELECT rv.id INTO v_rec_ver_id
            FROM public.recipe_versions rv
            JOIN public.recipe_master rm ON rv.recipe_master_id = rm.id
            WHERE rm.menu_item_id = r_item.product_id AND rv.status = 'Approved' LIMIT 1;

            IF v_rec_ver_id IS NOT NULL THEN
                FOR r_rec_item IN SELECT ingredient_id, quantity, waste_pct, yield_pct FROM public.recipe_items WHERE recipe_version_id = v_rec_ver_id LOOP
                    v_qty := r_item.quantity * r_rec_item.quantity * (1 + COALESCE(r_rec_item.waste_pct, 0) / 100) / (COALESCE(r_rec_item.yield_pct, 100) / 100);

                    IF NOT EXISTS (SELECT 1 FROM public.warehouse_stock WHERE warehouse_id = v_outlet_wh_id AND ingredient_id = r_rec_item.ingredient_id) THEN
                        INSERT INTO public.warehouse_stock (warehouse_id, ingredient_id, quantity, reserved_quantity) VALUES (v_outlet_wh_id, r_rec_item.ingredient_id, 0, 0);
                    END IF;

                    UPDATE public.warehouse_stock SET reserved_quantity = reserved_quantity + v_qty 
                    WHERE warehouse_id = v_outlet_wh_id AND ingredient_id = r_rec_item.ingredient_id;

                    UPDATE public.stock_master SET reserved_quantity = reserved_quantity + v_qty 
                    WHERE ingredient_id = r_rec_item.ingredient_id;
                END LOOP;
            END IF;
        END LOOP;

    -- CASE 2: Reservation Released
    ELSIF v_is_update AND v_new_status = 'Cancelled' AND v_old_status IN ('Pending', 'Created', 'Paid') THEN
        
        FOR r_item IN SELECT product_id, quantity FROM public.order_items WHERE order_id = NEW.id LOOP
            SELECT rv.id INTO v_rec_ver_id
            FROM public.recipe_versions rv
            JOIN public.recipe_master rm ON rv.recipe_master_id = rm.id
            WHERE rm.menu_item_id = r_item.product_id AND rv.status = 'Approved' LIMIT 1;

            IF v_rec_ver_id IS NOT NULL THEN
                FOR r_rec_item IN SELECT ingredient_id, quantity, waste_pct, yield_pct FROM public.recipe_items WHERE recipe_version_id = v_rec_ver_id LOOP
                    v_qty := r_item.quantity * r_rec_item.quantity * (1 + COALESCE(r_rec_item.waste_pct, 0) / 100) / (COALESCE(r_rec_item.yield_pct, 100) / 100);

                    UPDATE public.warehouse_stock SET reserved_quantity = GREATEST(0, reserved_quantity - v_qty) 
                    WHERE warehouse_id = v_outlet_wh_id AND ingredient_id = r_rec_item.ingredient_id;

                    UPDATE public.stock_master SET reserved_quantity = GREATEST(0, reserved_quantity - v_qty) 
                    WHERE ingredient_id = r_rec_item.ingredient_id;
                END LOOP;
            END IF;
        END LOOP;

    -- CASE 3: Reservation Released on Completion
    ELSIF v_is_update AND v_new_status = 'Completed' AND v_old_status IN ('Pending', 'Created', 'Paid') THEN
        
        FOR r_item IN SELECT product_id, quantity FROM public.order_items WHERE order_id = NEW.id LOOP
            SELECT rv.id INTO v_rec_ver_id
            FROM public.recipe_versions rv
            JOIN public.recipe_master rm ON rv.recipe_master_id = rm.id
            WHERE rm.menu_item_id = r_item.product_id AND rv.status = 'Approved' LIMIT 1;

            IF v_rec_ver_id IS NOT NULL THEN
                FOR r_rec_item IN SELECT ingredient_id, quantity, waste_pct, yield_pct FROM public.recipe_items WHERE recipe_version_id = v_rec_ver_id LOOP
                    v_qty := r_item.quantity * r_rec_item.quantity * (1 + COALESCE(r_rec_item.waste_pct, 0) / 100) / (COALESCE(r_rec_item.yield_pct, 100) / 100);

                    UPDATE public.warehouse_stock SET reserved_quantity = GREATEST(0, reserved_quantity - v_qty) 
                    WHERE warehouse_id = v_outlet_wh_id AND ingredient_id = r_rec_item.ingredient_id;

                    UPDATE public.stock_master SET reserved_quantity = GREATEST(0, reserved_quantity - v_qty) 
                    WHERE ingredient_id = r_rec_item.ingredient_id;
                END LOOP;
            END IF;
        END LOOP;

    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.deduct_recipe_item(
    p_ingredient_id BIGINT,
    p_qty NUMERIC,
    p_warehouse_id BIGINT,
    p_doc_type TEXT,
    p_doc_num TEXT,
    p_created_by TEXT,
    p_remarks TEXT
) RETURNS VOID AS $$
DECLARE
    v_item_type TEXT;
    v_avail_qty NUMERIC := 0;
    v_deficit NUMERIC := 0;
    v_recipe_master_id BIGINT;
    v_recipe_version_id BIGINT;
    r_rec_item RECORD;
    v_rec_qty NUMERIC;
BEGIN
    -- Retrieve ingredient classification
    SELECT COALESCE(item_type, 'Raw') INTO v_item_type FROM public.ingredient_master WHERE id = p_ingredient_id;
    
    IF v_item_type = 'Raw' THEN
        -- Deduct from physical raw batches
        PERFORM public.deduct_inventory_stock(p_ingredient_id, p_qty, p_warehouse_id, p_doc_type, p_doc_num, p_created_by, p_remarks);
    ELSE
        -- Check available stock level
        SELECT COALESCE(quantity, 0) INTO v_avail_qty 
        FROM public.warehouse_stock 
        WHERE warehouse_id = p_warehouse_id AND ingredient_id = p_ingredient_id;
        
        IF v_avail_qty >= p_qty THEN
            -- Deduct fully from physical produced batches
            PERFORM public.deduct_inventory_stock(p_ingredient_id, p_qty, p_warehouse_id, p_doc_type, p_doc_num, p_created_by, p_remarks);
        ELSE
            -- Decompose deficit into recipe components
            v_deficit := p_qty - v_avail_qty;
            IF v_avail_qty > 0 THEN
                PERFORM public.deduct_inventory_stock(p_ingredient_id, v_avail_qty, p_warehouse_id, p_doc_type, p_doc_num, p_created_by, p_remarks);
            END IF;
            
            -- Resolve active recipe version
            SELECT id INTO v_recipe_master_id FROM public.recipe_master WHERE ingredient_id = p_ingredient_id LIMIT 1;
            IF v_recipe_master_id IS NOT NULL THEN
                SELECT id INTO v_recipe_version_id FROM public.recipe_versions WHERE recipe_master_id = v_recipe_master_id AND status = 'Approved' LIMIT 1;
                
                IF v_recipe_version_id IS NOT NULL THEN
                    FOR r_rec_item IN 
                        SELECT ingredient_id, quantity, waste_pct, yield_pct 
                        FROM public.recipe_items 
                        WHERE recipe_version_id = v_recipe_version_id
                    LOOP
                        v_rec_qty := v_deficit * r_rec_item.quantity * (1 + COALESCE(r_rec_item.waste_pct, 0) / 100) / (COALESCE(r_rec_item.yield_pct, 100) / 100);
                        
                        -- Recursive recipe deduction
                        PERFORM public.deduct_recipe_item(r_rec_item.ingredient_id, v_rec_qty, p_warehouse_id, p_doc_type, p_doc_num, p_created_by, p_remarks);
                    END LOOP;
                ELSE
                    -- Deduct remainder (fallback to stock)
                    PERFORM public.deduct_inventory_stock(p_ingredient_id, v_deficit, p_warehouse_id, p_doc_type, p_doc_num, p_created_by, p_remarks);
                END IF;
            ELSE
                -- Fallback to stock
                PERFORM public.deduct_inventory_stock(p_ingredient_id, v_deficit, p_warehouse_id, p_doc_type, p_doc_num, p_created_by, p_remarks);
            END IF;
        END IF;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.process_production_completion(p_production_order_id BIGINT, p_warehouse_id BIGINT)
RETURNS VOID AS $$
DECLARE
    v_order RECORD;
    r_item RECORD;
    r_rec_item RECORD;
    v_recipe_master_id BIGINT;
    v_recipe_version_id BIGINT;
    v_sku TEXT;
    v_base_unit TEXT;
    v_name TEXT;
    v_ingredient_cost NUMERIC := 0;
    v_total_cost NUMERIC := 0;
    v_per_unit_cost NUMERIC := 0;
    v_item_qty_needed NUMERIC := 0;
    v_item_cost_value NUMERIC := 0;
    v_old_global_stock NUMERIC := 0;
    v_old_warehouse_stock NUMERIC := 0;
    v_new_avg_cost NUMERIC := 0;
    v_expiry DATE;
    v_warehouse_name TEXT;
BEGIN
    -- Fetch Production Order Header
    SELECT * INTO v_order FROM public.production_orders WHERE id = p_production_order_id;
    SELECT name INTO v_warehouse_name FROM public.warehouses WHERE id = p_warehouse_id;

    FOR r_item IN 
        SELECT * FROM public.production_order_items WHERE production_order_id = p_production_order_id
    LOOP
        IF COALESCE(r_item.quantity_produced, 0) > 0 THEN
            -- Fetch details of produced item
            SELECT name, sku, base_unit INTO v_name, v_sku, v_base_unit 
            FROM public.ingredient_master WHERE id = r_item.ingredient_id;

            -- Resolve approved recipe
            v_ingredient_cost := 0;
            SELECT id INTO v_recipe_master_id FROM public.recipe_master WHERE ingredient_id = r_item.ingredient_id LIMIT 1;
            
            IF v_recipe_master_id IS NOT NULL THEN
                SELECT id INTO v_recipe_version_id FROM public.recipe_versions WHERE recipe_master_id = v_recipe_master_id AND status = 'Approved' LIMIT 1;
                
                IF v_recipe_version_id IS NOT NULL THEN
                    FOR r_rec_item IN 
                        SELECT ri.ingredient_id, ri.quantity, ri.waste_pct, ri.yield_pct, im.avg_cost
                        FROM public.recipe_items ri
                        JOIN public.ingredient_master im ON ri.ingredient_id = im.id
                        WHERE ri.recipe_version_id = v_recipe_version_id
                    LOOP
                        v_item_qty_needed := r_item.quantity_produced * r_rec_item.quantity * (1 + COALESCE(r_rec_item.waste_pct, 0) / 100) / (COALESCE(r_rec_item.yield_pct, 100) / 100);
                        v_item_cost_value := v_item_qty_needed * COALESCE(r_rec_item.avg_cost, 0);
                        v_ingredient_cost := v_ingredient_cost + v_item_cost_value;

                        -- Deduct consumed ingredient recursively
                        PERFORM public.deduct_recipe_item(
                            r_rec_item.ingredient_id,
                            v_item_qty_needed,
                            p_warehouse_id,
                            'Production Intake',
                            v_order.production_code,
                            COALESCE(v_order.completed_by, 'Manish Kumar'),
                            'Consumption for product: ' || v_name
                        );
                    END LOOP;
                END IF;
            END IF;

            -- Calculate production costs
            v_total_cost := v_ingredient_cost + 
                            COALESCE(r_item.labour_cost, 0) + 
                            COALESCE(r_item.gas_cost, 0) + 
                            COALESCE(r_item.packaging_cost, 0) + 
                            COALESCE(r_item.utility_cost, 0);
            v_per_unit_cost := v_total_cost / r_item.quantity_produced;

            -- Get current global and local stock
            SELECT COALESCE(available_quantity, 0) INTO v_old_global_stock 
            FROM public.stock_master WHERE ingredient_id = r_item.ingredient_id;

            SELECT COALESCE(quantity, 0) INTO v_old_warehouse_stock 
            FROM public.warehouse_stock WHERE warehouse_id = p_warehouse_id AND ingredient_id = r_item.ingredient_id;

            IF NOT EXISTS (SELECT 1 FROM public.warehouse_stock WHERE warehouse_id = p_warehouse_id AND ingredient_id = r_item.ingredient_id) THEN
                INSERT INTO public.warehouse_stock (warehouse_id, ingredient_id, quantity) VALUES (p_warehouse_id, r_item.ingredient_id, 0);
                v_old_warehouse_stock := 0;
            END IF;

            -- Recalculate average costs
            SELECT 
                CASE 
                    WHEN (v_old_global_stock + r_item.quantity_produced) <= 0 THEN v_per_unit_cost
                    ELSE ((v_old_global_stock * COALESCE(im.avg_cost, 0)) + (r_item.quantity_produced * v_per_unit_cost)) / (v_old_global_stock + r_item.quantity_produced)
                END INTO v_new_avg_cost
            FROM public.ingredient_master im
            WHERE im.id = r_item.ingredient_id;

            -- Update ingredient costs
            UPDATE public.ingredient_master SET
                avg_cost = v_new_avg_cost,
                last_purchase_cost = v_per_unit_cost,
                updated_at = now()
            WHERE id = r_item.ingredient_id;

            -- Increment stock
            UPDATE public.warehouse_stock SET
                quantity = quantity + r_item.quantity_produced,
                updated_at = now()
            WHERE warehouse_id = p_warehouse_id AND ingredient_id = r_item.ingredient_id;

            UPDATE public.stock_master SET
                available_quantity = available_quantity + r_item.quantity_produced,
                updated_at = now()
            WHERE ingredient_id = r_item.ingredient_id;

            -- Create Batch
            v_expiry := CURRENT_DATE + 30; -- 30 days default shelf-life
            INSERT INTO public.ingredient_batches (
                batch_number,
                lot_number,
                ingredient_id,
                warehouse_id,
                mfg_date,
                expiry_date,
                original_qty,
                current_qty,
                unit_cost,
                landing_cost
            ) VALUES (
                'BAT-' || v_order.production_code || '-' || r_item.ingredient_id,
                'LOT-' || v_order.production_code,
                r_item.ingredient_id,
                p_warehouse_id,
                CURRENT_DATE,
                v_expiry,
                r_item.quantity_produced,
                r_item.quantity_produced,
                v_per_unit_cost,
                v_per_unit_cost
            );

            -- Log to Stock Ledger
            INSERT INTO public.stock_ledger (
                ingredient_id,
                document_type,
                document_number,
                sku,
                warehouse,
                batch_number,
                lot_number,
                expiry_date,
                opening_stock,
                stock_in,
                closing_stock,
                unit,
                average_cost,
                current_cost,
                landing_cost,
                created_by,
                remarks
            ) VALUES (
                r_item.ingredient_id,
                'Production',
                v_order.production_code,
                v_sku,
                v_warehouse_name,
                'BAT-' || v_order.production_code || '-' || r_item.ingredient_id,
                'LOT-' || v_order.production_code,
                v_expiry,
                v_old_warehouse_stock,
                r_item.quantity_produced,
                v_old_warehouse_stock + r_item.quantity_produced,
                v_base_unit,
                v_new_avg_cost,
                v_per_unit_cost,
                v_per_unit_cost,
                COALESCE(v_order.completed_by, 'Manish Kumar'),
                'Manufactured batch posting: ' || v_order.production_code
            );

            -- Recalculate dependent recipes costing
            PERFORM public.recalculate_recipe_costs_for_ingredient(r_item.ingredient_id);
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.sync_account_balances()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        UPDATE public.accounts 
        SET current_balance = current_balance + (NEW.debit - NEW.credit)
        WHERE id = NEW.account_id;
    ELSIF TG_OP = 'DELETE' THEN
        UPDATE public.accounts 
        SET current_balance = current_balance - (OLD.debit - OLD.credit)
        WHERE id = OLD.account_id;
    ELSIF TG_OP = 'UPDATE' THEN
        UPDATE public.accounts 
        SET current_balance = current_balance - (OLD.debit - OLD.credit) + (NEW.debit - NEW.credit)
        WHERE id = NEW.account_id;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.post_journal_entry(
    p_module TEXT,
    p_doc_id BIGINT,
    p_doc_code TEXT,
    p_narration TEXT,
    p_lines JSONB -- Array of { account_code: '...', debit: 0, credit: 0, narration: '...' }
) RETURNS BIGINT AS $$
DECLARE
    v_journal_id BIGINT;
    v_total_debit NUMERIC := 0;
    v_total_credit NUMERIC := 0;
    r_line RECORD;
    v_account_id BIGINT;
    v_entry_num TEXT;
BEGIN
    -- Verify balanced entry
    SELECT COALESCE(SUM((val->>'debit')::NUMERIC), 0) INTO v_total_debit FROM jsonb_array_elements(p_lines) val;
    SELECT COALESCE(SUM((val->>'credit')::NUMERIC), 0) INTO v_total_credit FROM jsonb_array_elements(p_lines) val;
    
    IF v_total_debit != v_total_credit THEN
        RAISE EXCEPTION 'Journal entry is unbalanced. Total Debit: %, Total Credit: %', v_total_debit, v_total_credit;
    END IF;
    
    IF v_total_debit = 0 THEN
         -- Skip empty/zero entries
         RETURN NULL;
    END IF;

    v_entry_num := 'JRN-' || Date_part('year', CURRENT_DATE)::TEXT || '-' || Lpad(nextval('public.journal_entry_seq')::TEXT, 6, '0');

    INSERT INTO public.journal_entries (
        entry_number, date, source_module, source_document_id, source_document_code, narration
    ) VALUES (
        v_entry_num, CURRENT_DATE, p_module, p_doc_id, p_doc_code, p_narration
    ) RETURNING id INTO v_journal_id;

    FOR r_line IN SELECT * FROM jsonb_to_recordset(p_lines) AS x(account_code TEXT, debit NUMERIC, credit NUMERIC, narration TEXT) LOOP
        SELECT id INTO v_account_id FROM public.accounts WHERE code = r_line.account_code;
        IF v_account_id IS NULL THEN
            RAISE EXCEPTION 'Account code % does not exist in Chart of Accounts', r_line.account_code;
        END IF;

        INSERT INTO public.journal_lines (
            journal_entry_id, account_id, debit, credit, narration
        ) VALUES (
            v_journal_id, v_account_id, COALESCE(r_line.debit, 0), COALESCE(r_line.credit, 0), COALESCE(r_line.narration, p_narration)
        );
    END LOOP;

    RETURN v_journal_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.handle_grn_completed_accounting()
RETURNS TRIGGER AS $$
DECLARE
    v_lines JSONB;
    v_invoice_amt NUMERIC;
    v_overhead NUMERIC;
    v_total NUMERIC;
BEGIN
    IF NEW.status = 'Completed' AND (OLD.status IS NULL OR OLD.status != 'Completed') THEN
        v_invoice_amt := COALESCE(NEW.invoice_amount, 0);
        v_overhead := COALESCE(NEW.freight_charge, 0) + 
                      COALESCE(NEW.insurance_charge, 0) + 
                      COALESCE(NEW.loading_charge, 0) + 
                      COALESCE(NEW.packing_charge, 0) + 
                      COALESCE(NEW.transport_charge, 0) + 
                      COALESCE(NEW.other_charges, 0);
        v_total := v_invoice_amt + v_overhead;

        IF v_total > 0 THEN
            v_lines := jsonb_build_array(
                jsonb_build_object('account_code', '130000', 'debit', v_total, 'credit', 0, 'narration', 'Raw inventory receipts for ' || NEW.grn_code),
                jsonb_build_object('account_code', '210000', 'debit', 0, 'credit', v_total, 'narration', 'Outstanding liability for GRN ' || NEW.grn_code)
            );

            PERFORM public.post_journal_entry(
                'Procurement',
                NEW.id,
                NEW.grn_code,
                'Automated journal posting for Goods Receipt: ' || NEW.grn_code,
                v_lines
            );
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.handle_vendor_payment_accounting()
RETURNS TRIGGER AS $$
DECLARE
    v_lines JSONB;
BEGIN
    -- Check if it is a vendor payment transaction
    IF NEW.transaction_type = 'Payment' THEN
        v_lines := jsonb_build_array(
            jsonb_build_object('account_code', '210000', 'debit', NEW.amount, 'credit', 0, 'narration', 'Clearing vendor liability: ' || NEW.reference_id),
            jsonb_build_object('account_code', '120000', 'debit', 0, 'credit', NEW.amount, 'narration', 'Payment released via Bank: ' || NEW.reference_id)
        );

        PERFORM public.post_journal_entry(
            'Procurement',
            NEW.id,
            NEW.reference_id,
            'Automated payment journal: ' || NEW.reference_id,
            v_lines
        );
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.handle_pos_sales_accounting()
RETURNS TRIGGER AS $$
DECLARE
    v_lines JSONB;
    v_subtotal NUMERIC := 0;
    v_cgst NUMERIC := 0;
    v_sgst NUMERIC := 0;
    v_total NUMERIC := 0;
    v_payment_mode TEXT;
    v_cash_code TEXT := '110000';
    v_bank_code TEXT := '120000';
    v_pay_code TEXT;
    v_ref_num TEXT;
BEGIN
    -- Support both 'Completed' and 'Closed' order statuses
    IF NEW.status IN ('Completed', 'Closed') AND (OLD.status IS NULL OR OLD.status NOT IN ('Completed', 'Closed')) THEN
        v_total := COALESCE(NEW.total, 0);
        
        -- Resolve payment mode from payment_method
        v_payment_mode := COALESCE(NEW.payment_method, 'Cash');

        -- Determine debit target cash or bank
        IF v_payment_mode IN ('Card', 'UPI', 'NEFT', 'Bank') THEN
            v_pay_code := v_bank_code;
        ELSE
            v_pay_code := v_cash_code;
        END IF;

        -- Resolve reference order identifier from offline_sync_id
        v_ref_num := COALESCE(NEW.offline_sync_id, NEW.id::text);

        -- Resolve CGST and SGST by splitting total GST evenly
        v_cgst := ROUND((COALESCE(NEW.gst, 0) / 2.0), 2);
        v_sgst := ROUND((COALESCE(NEW.gst, 0) / 2.0), 2);
        v_subtotal := v_total - (v_cgst + v_sgst);

        IF v_total > 0 THEN
            v_lines := jsonb_build_array(
                jsonb_build_object('account_code', v_pay_code, 'debit', v_total, 'credit', 0, 'narration', 'Sales receipts: order #' || v_ref_num),
                jsonb_build_object('account_code', '410000', 'debit', 0, 'credit', v_subtotal, 'narration', 'POS Sales revenue: #' || v_ref_num)
            );

            -- Add CGST/SGST if applicable
            IF v_cgst > 0 THEN
                v_lines := v_lines || jsonb_build_object('account_code', '221000', 'debit', 0, 'credit', v_cgst, 'narration', 'CGST collected: #' || v_ref_num);
            END IF;
            IF v_sgst > 0 THEN
                v_lines := v_lines || jsonb_build_object('account_code', '222000', 'debit', 0, 'credit', v_sgst, 'narration', 'SGST collected: #' || v_ref_num);
            END IF;

            PERFORM public.post_journal_entry(
                'POS',
                NEW.id,
                v_ref_num,
                'POS Sale completed: order #' || v_ref_num,
                v_lines
            );
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.handle_wastage_accounting()
RETURNS TRIGGER AS $$
DECLARE
    v_lines JSONB;
    v_total_cost NUMERIC := 0;
BEGIN
    IF NEW.status = 'Approved' AND (OLD.status IS NULL OR OLD.status != 'Approved') THEN
        -- Sum up total cost impact of wasted items
        SELECT COALESCE(SUM(cost_impact), 0) INTO v_total_cost 
        FROM public.wastage_items WHERE wastage_id = NEW.id;

        IF v_total_cost > 0 THEN
            v_lines := jsonb_build_array(
                jsonb_build_object('account_code', '580000', 'debit', v_total_cost, 'credit', 0, 'narration', 'Wastage write-off: ' || NEW.wastage_code),
                jsonb_build_object('account_code', '130000', 'debit', 0, 'credit', v_total_cost, 'narration', 'Inventory deduction for spoilage: ' || NEW.wastage_code)
            );

            PERFORM public.post_journal_entry(
                'Inventory',
                NEW.id,
                NEW.wastage_code,
                'Wastage approved write-off: ' || NEW.wastage_code,
                v_lines
            );
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.get_erp_health_metrics()
RETURNS JSONB AS $$
DECLARE
    v_db_status TEXT := 'Healthy';
    v_connections INTEGER := 1;
    v_negative_stock INTEGER := 0;
    v_negative_cost INTEGER := 0;
    v_unbalanced_journals INTEGER := 0;
    v_orphan_ledgers INTEGER := 0;
    v_duplicate_pos INTEGER := 0;
    v_duplicate_grns INTEGER := 0;
    v_duplicate_invoices INTEGER := 0;
    v_missing_recipes INTEGER := 0;
    v_missing_suppliers INTEGER := 0;
    v_health_score INTEGER := 100;
    v_result JSONB;
BEGIN
    -- 1. Check for negative stocks
    SELECT COALESCE(COUNT(*), 0) INTO v_negative_stock 
    FROM public.warehouse_stock WHERE quantity < 0;

    -- 2. Check for negative costs
    SELECT COALESCE(COUNT(*), 0) INTO v_negative_cost 
    FROM public.ingredient_master WHERE avg_cost < 0;

    -- 3. Check for unbalanced journal lines
    SELECT COALESCE(COUNT(*), 0) INTO v_unbalanced_journals 
    FROM (
        SELECT journal_entry_id, SUM(debit) d, SUM(credit) c 
        FROM public.journal_lines 
        GROUP BY journal_entry_id
    ) x WHERE x.d != x.c;

    -- 4. Check for orphan stock ledger references
    SELECT COALESCE(COUNT(*), 0) INTO v_orphan_ledgers 
    FROM public.stock_ledger sl 
    LEFT JOIN public.ingredient_master im ON sl.ingredient_id = im.id 
    WHERE im.id IS NULL;

    -- 5. Check for duplicate PO reference codes
    SELECT COALESCE(COUNT(*), 0) INTO v_duplicate_pos 
    FROM (
        SELECT po_code, COUNT(*) c 
        FROM public.purchase_orders 
        GROUP BY po_code 
        HAVING COUNT(*) > 1
    ) x;

    -- 6. Check for duplicate GRN reference codes
    SELECT COALESCE(COUNT(*), 0) INTO v_duplicate_grns 
    FROM (
        SELECT grn_code, COUNT(*) c 
        FROM public.grns 
        GROUP BY grn_code 
        HAVING COUNT(*) > 1
    ) x;

    -- 7. Check for duplicate invoice references
    SELECT COALESCE(COUNT(*), 0) INTO v_duplicate_invoices 
    FROM (
        SELECT invoice_number, COUNT(*) c 
        FROM public.grns 
        GROUP BY invoice_number 
        HAVING COUNT(*) > 1
    ) x;

    -- 8. Check for missing recipes on produced preps
    SELECT COALESCE(COUNT(*), 0) INTO v_missing_recipes 
    FROM public.ingredient_master 
    WHERE item_type IN ('Semi-Finished', 'Finished') 
      AND id NOT IN (SELECT ingredient_id FROM public.recipe_master WHERE ingredient_id IS NOT NULL);

    -- Calculate dynamic overall ERP health score
    IF v_negative_stock > 0 THEN v_health_score := v_health_score - 10; END IF;
    IF v_negative_cost > 0 THEN v_health_score := v_health_score - 10; END IF;
    IF v_unbalanced_journals > 0 THEN v_health_score := v_health_score - 20; END IF;
    IF v_orphan_ledgers > 0 THEN v_health_score := v_health_score - 5; END IF;
    IF v_duplicate_pos > 0 THEN v_health_score := v_health_score - 5; END IF;
    IF v_duplicate_grns > 0 THEN v_health_score := v_health_score - 5; END IF;
    IF v_duplicate_invoices > 0 THEN v_health_score := v_health_score - 5; END IF;
    IF v_missing_recipes > 0 THEN v_health_score := v_health_score - 10; END IF;
    
    -- Ensure health score remains within 0-100 limits
    IF v_health_score < 0 THEN v_health_score := 0; END IF;

    -- Compile JSONB result package
    v_result := jsonb_build_object(
        'database_status', v_db_status,
        'connection_count', v_connections,
        'negative_stock_count', v_negative_stock,
        'negative_cost_count', v_negative_cost,
        'unbalanced_journal_count', v_unbalanced_journals,
        'orphan_ledger_count', v_orphan_ledgers,
        'duplicate_po_count', v_duplicate_pos,
        'duplicate_grn_count', v_duplicate_grns,
        'duplicate_invoice_count', v_duplicate_invoices,
        'missing_recipes_count', v_missing_recipes,
        'overall_health_score', v_health_score
    );

    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.handle_rider_cash_collection()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status = 'Delivered' AND (OLD.status IS NULL OR OLD.status != 'Delivered') THEN
        IF NEW.rider_id IS NOT NULL AND NEW.payment_method = 'COD' THEN
            UPDATE public.delivery_riders
            SET cash_collected = cash_collected + COALESCE(NEW.grand_total, 0)
            WHERE id = NEW.rider_id;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.handle_delivery_settlement_accounting()
RETURNS TRIGGER AS $$
DECLARE
    v_lines JSONB;
    v_rider_name TEXT;
BEGIN
    IF NEW.status = 'Approved' AND (OLD.status IS NULL OR OLD.status != 'Approved') THEN
        -- Clear rider cash bucket
        UPDATE public.delivery_riders
        SET cash_collected = GREATEST(0, cash_collected - NEW.cash_expected),
            updated_at = NOW()
        WHERE id = NEW.rider_id;

        SELECT name INTO v_rider_name FROM public.delivery_riders WHERE id = NEW.rider_id;

        -- Create general ledger double-entry lines
        -- Debit: Cash Account (110000) for cash received
        -- Credit: Sales Revenue (410000) / driver outstanding clear
        v_lines := jsonb_build_array(
            jsonb_build_object('account_code', '110000', 'debit', NEW.cash_received, 'credit', 0, 'narration', 'Cash settled from rider ' || v_rider_name),
            jsonb_build_object('account_code', '410000', 'debit', 0, 'credit', NEW.cash_received, 'narration', 'Reconciliation clear for rider ' || v_rider_name)
        );

        PERFORM public.post_journal_entry(
            'Manual',
            NEW.id,
            'SETTLE-' || NEW.id,
            'Rider cash settlement journal: ' || v_rider_name,
            v_lines
        );
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.handle_eip_event_bus_logging()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO public.eip_integration_logs (type, name, request_payload, response_payload, status, latency_ms)
    VALUES ('Event', NEW.event_name, NEW.payload, jsonb_build_object('event_bus_id', NEW.id, 'status', NEW.status), 'Success', 15);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.handle_iam_modification_audit()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO public.iam_security_audit (performed_by, action, remarks, ip_address)
    VALUES ('System Steward', TG_OP || ' ' || TG_TABLE_NAME, 'Record identifier code mapping: ' || NEW.code, '127.0.0.1');
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.get_current_user_email_or_system()
RETURNS TEXT AS $$
DECLARE
    v_email TEXT;
BEGIN
    SELECT email INTO v_email FROM public.users WHERE id = public.get_current_user_id() LIMIT 1;
    RETURN COALESCE(v_email, 'System');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

CREATE OR REPLACE FUNCTION public.exec_sql(p_sql TEXT)
RETURNS JSONB AS $$
DECLARE
    v_row RECORD;
    v_arr JSONB := '[]'::jsonb;
BEGIN
    IF UPPER(TRIM(p_sql)) LIKE 'SELECT%' OR UPPER(TRIM(p_sql)) LIKE 'EXPLAIN%' THEN
        FOR v_row IN EXECUTE p_sql LOOP
            v_arr := v_arr || to_jsonb(v_row);
        END LOOP;
        RETURN jsonb_build_object('success', true, 'data', v_arr);
    ELSE
        EXECUTE p_sql;
        RETURN jsonb_build_object('success', true);
    END IF;
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.secure_validate_coupon(
    p_code TEXT,
    p_subtotal NUMERIC,
    p_user_id BIGINT,
    p_channel TEXT DEFAULT 'website'
)
RETURNS JSONB AS $$
DECLARE
    v_coupon RECORD;
    v_user_orders_count INT;
    v_overall_orders_count INT;
    v_user_usage_count INT;
    v_user_phone TEXT;
    v_user_mobile TEXT;
    v_user_email TEXT;
    v_channels JSONB;
    v_has_channel BOOLEAN := FALSE;
BEGIN
    -- Query the coupons table
    SELECT * INTO v_coupon 
    FROM public.coupons 
    WHERE code = p_code AND active = TRUE 
    LIMIT 1;

    -- If not found in coupons, fallback check on legacy offers table
    IF v_coupon IS NULL THEN
        DECLARE
            v_offer RECORD;
        BEGIN
            SELECT * INTO v_offer 
            FROM public.offers 
            WHERE code = p_code AND active = TRUE 
            LIMIT 1;

            IF v_offer IS NULL THEN
                RETURN jsonb_build_object('valid', false, 'error', 'Invalid or inactive coupon code');
            END IF;

            -- Convert legacy offer structure dynamically to unified record format
            v_coupon.id := v_offer.id;
            v_coupon.code := v_offer.code;
            v_coupon.discount_type := v_offer.discount_type;
            v_coupon.discount_value := COALESCE(v_offer.discount_value, 0.0);
            v_coupon.max_discount := v_offer.max_discount;
            v_coupon.min_order := COALESCE(v_offer.min_order, 0.0);
            v_coupon.expiry_date := v_offer.expiry_date;
            v_coupon.usage_limit := v_offer.usage_limit;
            v_coupon.user_usage_limit := v_offer.user_usage_limit;
            v_coupon.user_type := v_offer.user_type;
            v_coupon.specific_users := v_offer.specific_users;
            v_coupon.available_channels := v_offer.available_channels;
        END;
    END IF;

    -- Check availability channels
    v_channels := COALESCE(v_coupon.available_channels, '["website"]'::jsonb);
    SELECT (v_channels @> jsonb_build_array(p_channel)) INTO v_has_channel;
    
    IF NOT v_has_channel THEN
        IF p_channel = 'pos' THEN
            RETURN jsonb_build_object('valid', false, 'error', 'This coupon is not available on POS.');
        ELSE
            RETURN jsonb_build_object('valid', false, 'error', 'This coupon is not available on this channel');
        END IF;
    END IF;

    -- 1. Expiry check
    IF v_coupon.expiry_date IS NOT NULL AND v_coupon.expiry_date < NOW() THEN
        RETURN jsonb_build_object('valid', false, 'error', 'This coupon has expired');
    END IF;

    -- 2. Minimum order check
    IF p_subtotal < v_coupon.min_order THEN
        RETURN jsonb_build_object('valid', false, 'error', 'Minimum order amount for this coupon is ₹' || v_coupon.min_order);
    END IF;

    -- Fetch user phone, mobile, and email for specific target validation
    IF p_user_id IS NOT NULL THEN
        SELECT phone, mobile, email INTO v_user_phone, v_user_mobile, v_user_email 
        FROM public.users 
        WHERE id = p_user_id;
    END IF;

    -- 3. Specific user check (checking user ID, phone, mobile, and email)
    IF v_coupon.user_type = 'specific' THEN
        IF p_user_id IS NULL OR v_coupon.specific_users IS NULL OR (
            NOT (v_coupon.specific_users LIKE '%' || p_user_id::text || '%') AND
            (v_user_phone IS NULL OR NOT (v_coupon.specific_users LIKE '%' || v_user_phone || '%')) AND
            (v_user_mobile IS NULL OR NOT (v_coupon.specific_users LIKE '%' || v_user_mobile || '%')) AND
            (v_user_email IS NULL OR NOT (LOWER(v_coupon.specific_users) LIKE '%' || LOWER(v_user_email) || '%'))
        ) THEN
            RETURN jsonb_build_object('valid', false, 'error', 'This coupon is not valid for your account');
        END IF;
    END IF;

    -- 4. New/Existing user eligibility check
    IF v_coupon.user_type IN ('new_users', 'existing_users') THEN
        SELECT COUNT(*) INTO v_user_orders_count 
        FROM public.orders 
        WHERE user_id = p_user_id AND status <> 'Cancelled';

        IF v_coupon.user_type = 'new_users' AND v_user_orders_count > 0 THEN
            RETURN jsonb_build_object('valid', false, 'error', 'This coupon is only valid for your first order');
        END IF;

        IF v_coupon.user_type = 'existing_users' AND v_user_orders_count = 0 THEN
            RETURN jsonb_build_object('valid', false, 'error', 'This coupon is only valid for repeat customers');
        END IF;
    END IF;

    -- 5. Overall usage limit check
    IF v_coupon.usage_limit IS NOT NULL THEN
        SELECT COUNT(*) INTO v_overall_orders_count 
        FROM public.orders 
        WHERE coupon_code = p_code AND status <> 'Cancelled';

        IF v_overall_orders_count >= v_coupon.usage_limit THEN
            RETURN jsonb_build_object('valid', false, 'error', 'This coupon has reached its maximum usage limit');
        END IF;
    END IF;

    -- 6. Per-user usage limit check
    IF v_coupon.user_usage_limit IS NOT NULL THEN
        SELECT COUNT(*) INTO v_user_usage_count 
        FROM public.orders 
        WHERE user_id = p_user_id AND coupon_code = p_code AND status <> 'Cancelled';

        IF v_user_usage_count >= v_coupon.user_usage_limit THEN
            RETURN jsonb_build_object('valid', false, 'error', 'You have already used this coupon ' || v_coupon.user_usage_limit || ' times');
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'valid', true,
        'coupon_id', v_coupon.id,
        'discount_type', v_coupon.discount_type,
        'discount_value', v_coupon.discount_value,
        'max_discount', v_coupon.max_discount
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.secure_redeem_pos_wallet(
    p_phone TEXT,
    p_order_id TEXT,
    p_coins INTEGER,
    p_idempotency_key TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_user_id BIGINT;
    v_wallet RECORD;
    v_settings RECORD;
    v_ratio NUMERIC := 1.0;
    v_rupee_val NUMERIC;
    v_clean_phone TEXT;
    v_ref_key TEXT;
BEGIN
    IF p_coins <= 0 THEN
        RETURN jsonb_build_object('success', true, 'message', 'No coins to redeem');
    END IF;

    v_ref_key := COALESCE(p_idempotency_key, p_order_id);

    -- Clean phone number format
    v_clean_phone := regexp_replace(p_phone, '\D', '', 'g');
    IF starts_with(v_clean_phone, '91') AND length(v_clean_phone) = 12 THEN
        v_clean_phone := substr(v_clean_phone, 3);
    END IF;

    -- Resolve user_id from phone or direct user_id numeric string
    IF p_phone ~ '^\d+$' AND length(p_phone) < 10 THEN
        v_user_id := p_phone::BIGINT;
    ELSE
        SELECT id INTO v_user_id FROM public.users WHERE phone = v_clean_phone LIMIT 1;
    END IF;

    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Customer profile not found', 'is_business_error', true);
    END IF;

    -- Idempotency Protection: Check if already redeemed for this order or idempotency key
    IF EXISTS (
        SELECT 1 FROM public.cheesy_wallet_transactions 
        WHERE user_id = v_user_id 
          AND reference_type = 'order' 
          AND (reference_id = p_order_id OR reference_id = v_ref_key) 
          AND transaction_type = 'redeem'
    ) THEN
        RETURN jsonb_build_object('success', true, 'message', 'Already redeemed for this order');
    END IF;

    -- Row Locking for Concurrency Protection
    SELECT * INTO v_wallet FROM public.cheesy_wallets WHERE user_id = v_user_id FOR UPDATE;
    IF v_wallet IS NULL OR v_wallet.wallet_status <> 'active' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Wallet inactive or frozen', 'is_business_error', true);
    END IF;

    IF v_wallet.available_coins < p_coins THEN
        RETURN jsonb_build_object('success', false, 'error', 'Insufficient wallet balance', 'is_business_error', true);
    END IF;

    SELECT * INTO v_settings FROM public.cheesy_wallet_settings WHERE id = 1 LIMIT 1;
    IF v_settings IS NOT NULL THEN
        v_ratio := COALESCE(v_settings.coin_ratio_rupees / NULLIF(v_settings.coin_ratio_coins, 0), 1.0);
    END IF;
    v_rupee_val := p_coins * v_ratio;

    -- Deduct Available Balance
    UPDATE public.cheesy_wallets
    SET available_coins = GREATEST(0, available_coins - p_coins),
        lifetime_redeemed = lifetime_redeemed + p_coins,
        updated_at = NOW()
    WHERE user_id = v_user_id;

    -- Log Transaction Record
    INSERT INTO public.cheesy_wallet_transactions (
        user_id, transaction_type, coins, rupee_value, reference_type, reference_id, remarks
    ) VALUES (
        v_user_id, 'redeem', -p_coins, -v_rupee_val, 'order', v_ref_key, 'POS Redemption on Order #' || p_order_id
    );

    RETURN jsonb_build_object('success', true, 'coins_redeemed', p_coins, 'rupee_value', v_rupee_val);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.secure_get_or_create_customer_session(
    p_user_id BIGINT,
    p_phone TEXT DEFAULT NULL,
    p_pin TEXT DEFAULT NULL
)
RETURNS TEXT AS $$
DECLARE
    v_user RECORD;
    v_token TEXT;
    v_expires TIMESTAMPTZ;
    v_caller_user_id BIGINT;
    v_is_authorized BOOLEAN := FALSE;
BEGIN
    -- Validate p_user_id parameter
    IF p_user_id IS NULL OR p_user_id <= 0 THEN
        RETURN NULL;
    END IF;

    -- Locate exact user profile by primary key id
    SELECT * INTO v_user 
    FROM public.users 
    WHERE id = p_user_id
    LIMIT 1;

    IF v_user IS NULL THEN
        RETURN NULL;
    END IF;

    -- If phone is provided, verify it matches the user's phone or mobile
    IF p_phone IS NOT NULL AND p_phone <> '' THEN
        IF v_user.phone IS DISTINCT FROM p_phone AND v_user.mobile IS DISTINCT FROM p_phone THEN
            -- Mismatched phone lookup attempt: fail securely
            RETURN NULL;
        END IF;
    END IF;

    -- Verify CALLER AUTHORIZATION:
    -- Check if caller is already authenticated via x-cheesy-token
    v_caller_user_id := public.get_current_user_id();

    IF v_caller_user_id IS NOT NULL THEN
        -- Active authenticated session caller: MUST match p_user_id
        IF v_caller_user_id = v_user.id THEN
            v_is_authorized := TRUE;
        ELSE
            -- User A attempting to acquire User B session token -> REJECT!
            RETURN NULL;
        END IF;
    ELSIF p_pin IS NOT NULL AND p_pin <> '' THEN
        -- Unauthenticated caller presenting PIN: verify PIN match against pin_hash
        IF v_user.pin_hash IS NOT NULL AND 
           replace(v_user.pin_hash, '$2b$', '$2a$') = extensions.crypt(p_pin, replace(v_user.pin_hash, '$2b$', '$2a$')) THEN
            v_is_authorized := TRUE;
        ELSE
            RETURN NULL;
        END IF;
    ELSE
        -- Anonymous / unauthenticated caller with no valid session header and no PIN -> REJECT!
        RETURN NULL;
    END IF;

    IF NOT v_is_authorized THEN
        RETURN NULL;
    END IF;

    -- Look for existing active unexpired session strictly owned by v_user.id
    SELECT token INTO v_token 
    FROM public.active_sessions 
    WHERE user_id = v_user.id AND expires_at > NOW() 
    ORDER BY expires_at DESC
    LIMIT 1;

    IF v_token IS NOT NULL THEN
        RETURN v_token;
    END IF;

    -- Generate new session token for v_user.id (valid for 30 days)
    v_token := encode(extensions.gen_random_bytes(32), 'hex');
    v_expires := NOW() + INTERVAL '30 days';

    INSERT INTO public.active_sessions (user_id, token, ip_address, device, location, expires_at)
    VALUES (v_user.id, v_token, '127.0.0.1', 'Web Client', 'Customer Session', v_expires);

    RETURN v_token;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.secure_touch_session(p_token TEXT)
RETURNS JSONB AS $$
DECLARE
    v_session RECORD;
    v_new_expires TIMESTAMPTZ;
BEGIN
    SELECT * INTO v_session
    FROM public.active_sessions
    WHERE token = p_token AND expires_at > NOW()
    LIMIT 1;

    IF v_session IS NULL THEN
        -- Session doesn't exist or has already expired -- nothing to
        -- extend. Not an error: the caller's own secure_get_session call
        -- already gates this codepath on the session being valid, but we
        -- guard here too in case of a race (e.g. session expired between
        -- the two calls).
        RETURN jsonb_build_object('success', false, 'reason', 'invalid_or_expired');
    END IF;

    v_new_expires := NOW() + INTERVAL '24 hours';

    UPDATE public.active_sessions
    SET expires_at = v_new_expires
    WHERE token = p_token;

    RETURN jsonb_build_object('success', true, 'expires_at', v_new_expires);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.secure_submit_qr_table_order(
  p_table_id BIGINT,
  p_table_session_id BIGINT DEFAULT NULL,
  p_session_token TEXT DEFAULT NULL,
  p_customer_name TEXT DEFAULT NULL,
  p_phone TEXT DEFAULT NULL,
  p_address TEXT DEFAULT NULL,
  p_payment_method TEXT DEFAULT 'Pay at Counter',
  p_payment_status TEXT DEFAULT 'Unpaid',
  p_subtotal NUMERIC DEFAULT 0,
  p_gst NUMERIC DEFAULT 0,
  p_delivery_fee NUMERIC DEFAULT 0,
  p_total NUMERIC DEFAULT 0,
  p_notes TEXT DEFAULT '',
  p_offline_sync_id TEXT DEFAULT NULL,
  p_business_date DATE DEFAULT CURRENT_DATE,
  p_items JSONB DEFAULT '[]'::jsonb
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_session RECORD;
  v_table RECORD;
  v_order_id BIGINT;
  v_table_number TEXT;
  v_resolved_session_id BIGINT;
BEGIN
  -- 1. Validate inputs
  IF p_table_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'invalid_input', 'message', 'Table ID is required.');
  END IF;

  IF p_table_session_id IS NULL AND (p_session_token IS NULL OR trim(p_session_token) = '') THEN
    RETURN jsonb_build_object('success', false, 'error', 'invalid_input', 'message', 'Table session identifier is required.');
  END IF;

  -- 2. Lock and fetch table_sessions row for update
  SELECT id, table_id, status, session_token INTO v_session
  FROM public.table_sessions
  WHERE (p_table_session_id IS NOT NULL AND id = p_table_session_id)
     OR (p_session_token IS NOT NULL AND session_token = p_session_token)
  LIMIT 1
  FOR UPDATE;

  IF v_session.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'stale_session_mismatch', 'message', 'Session not found.');
  END IF;

  IF v_session.status != 'active' THEN
    RETURN jsonb_build_object('success', false, 'error', 'stale_session_mismatch', 'message', 'Table session is no longer active.');
  END IF;

  IF v_session.table_id != p_table_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'stale_session_mismatch', 'message', 'Session does not belong to specified table.');
  END IF;

  v_resolved_session_id := v_session.id;

  -- 3. Lock and fetch pos_tables row for update
  SELECT id, active_session_id, status, COALESCE(name, table_number, id::text) AS table_name INTO v_table
  FROM public.pos_tables
  WHERE id = p_table_id
  FOR UPDATE;

  IF v_table.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'table_not_found', 'message', 'Table not found.');
  END IF;

  IF v_table.active_session_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'stale_session_mismatch', 'message', 'Table has no active session.');
  END IF;

  -- active_session_id can be stored as numeric id or string token
  IF v_table.active_session_id::text != v_session.id::text 
     AND v_table.active_session_id::text != v_session.session_token THEN
    RETURN jsonb_build_object('success', false, 'error', 'stale_session_mismatch', 'message', 'Table active session mismatch.');
  END IF;

  v_table_number := v_table.table_name;

  -- 4. Atomically insert into pos_orders
  INSERT INTO public.pos_orders (
    customer_name,
    phone,
    address,
    payment_method,
    payment_status,
    subtotal,
    gst,
    delivery_fee,
    total,
    status,
    delivery_mode,
    order_source,
    table_id,
    table_session_id,
    notes,
    offline_sync_id,
    business_date
  ) VALUES (
    p_customer_name,
    p_phone,
    p_address,
    p_payment_method,
    p_payment_status,
    p_subtotal,
    p_gst,
    p_delivery_fee,
    p_total,
    'waiting_confirmation',
    'dinein',
    'QR_TABLE',
    p_table_id,
    v_resolved_session_id,
    COALESCE(p_notes, ''),
    p_offline_sync_id,
    COALESCE(p_business_date, CURRENT_DATE)
  )
  RETURNING id INTO v_order_id;

  -- 5. Atomically insert into pos_order_items
  IF p_items IS NOT NULL AND jsonb_array_length(p_items) > 0 THEN
    INSERT INTO public.pos_order_items (
      order_id,
      product_id,
      product_name,
      product_image,
      variant_name,
      addons,
      quantity,
      price,
      total,
      item_final_price,
      status,
      combo_snapshot
    )
    SELECT
      v_order_id,
      (item->>'product_id')::bigint,
      item->>'product_name',
      item->>'product_image',
      item->>'variant_name',
      COALESCE(item->>'addons', '[]'),
      COALESCE((item->>'quantity')::int, 1),
      COALESCE((item->>'price')::numeric, 0),
      COALESCE((item->>'total')::numeric, 0),
      COALESCE((item->>'price')::numeric, 0),
      'Pending',
      CASE WHEN item->'combo_snapshot' IS NOT NULL THEN (item->'combo_snapshot')::jsonb ELSE NULL END
    FROM jsonb_array_elements(p_items) AS item;

    -- [QR ITEM IDENTITY] Persist the POS line identity on the rows just
    -- inserted for this brand-new order (same transaction). The value is
    -- byte-identical to qrOrderAcceptService.js deriveStableQrLineUuid(id),
    -- so the POS accept/KOT lines and every later secure_sync_pos_order
    -- call resolve to THIS row instead of inserting a duplicate.
    UPDATE public.pos_order_items
    SET session_item_id = substr(lpad(to_hex(id), 32, '0'), 1, 8) || '-' || substr(lpad(to_hex(id), 32, '0'), 9, 4) || '-5' || substr(lpad(to_hex(id), 32, '0'), 14, 3) || '-a' || substr(lpad(to_hex(id), 32, '0'), 18, 3) || '-' || substr(lpad(to_hex(id), 32, '0'), 21, 12)
    WHERE order_id = v_order_id
      AND session_item_id IS NULL;
  END IF;

  -- 6. Atomically insert notification
  INSERT INTO public.pos_table_notifications (
    table_id,
    table_number,
    type,
    status
  ) VALUES (
    p_table_id,
    v_table_number,
    'new_order',
    'pending'
  );

  RETURN jsonb_build_object(
    'success', true,
    'order_id', v_order_id,
    'offline_sync_id', p_offline_sync_id,
    'table_session_id', v_resolved_session_id
  );
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'server_error',
      'message', SQLERRM
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.validate_active_session_internal(
    p_token TEXT,
    p_required_permission TEXT DEFAULT NULL
)
RETURNS TABLE (
    user_id BIGINT,
    role TEXT,
    branch_id BIGINT,
    is_valid BOOLEAN,
    error_code TEXT
) AS $$
DECLARE
    v_session RECORD;
    v_user RECORD;
    v_has_perm BOOLEAN := FALSE;
BEGIN
    -- 1. Check for empty/null token
    IF p_token IS NULL OR trim(p_token) = '' THEN
        RETURN QUERY SELECT NULL::BIGINT, NULL::TEXT, NULL::BIGINT, FALSE, 'EMPTY_TOKEN'::TEXT;
        RETURN;
    END IF;

    -- 2. Lookup active session
    SELECT * INTO v_session
    FROM public.active_sessions
    WHERE token = p_token
    LIMIT 1;

    IF v_session IS NULL THEN
        RETURN QUERY SELECT NULL::BIGINT, NULL::TEXT, NULL::BIGINT, FALSE, 'INVALID_TOKEN'::TEXT;
        RETURN;
    END IF;

    -- 3. Check session expiry
    IF v_session.expires_at <= NOW() THEN
        RETURN QUERY SELECT NULL::BIGINT, NULL::TEXT, NULL::BIGINT, FALSE, 'EXPIRED_SESSION'::TEXT;
        RETURN;
    END IF;

    -- 4. Resolve active user
    SELECT * INTO v_user
    FROM public.users
    WHERE id = v_session.user_id AND status = 'active'
    LIMIT 1;

    IF v_user IS NULL THEN
        RETURN QUERY SELECT NULL::BIGINT, NULL::TEXT, NULL::BIGINT, FALSE, 'INACTIVE_OR_MISSING_USER'::TEXT;
        RETURN;
    END IF;

    -- 5. Optional Permission Check
    IF p_required_permission IS NOT NULL AND trim(p_required_permission) <> '' THEN
        -- Super Admin and Admin bypass explicit permission check
        IF v_user.role = 'super_admin' OR v_user.role = 'admin' THEN
            v_has_perm := TRUE;
        ELSE
            -- Check direct user permission
            IF EXISTS (
                SELECT 1 FROM public.user_permissions
                WHERE user_id = v_user.id AND permission_id = p_required_permission
            ) THEN
                v_has_perm := TRUE;
            -- Check role permissions via user_roles
            ELSIF EXISTS (
                SELECT 1 
                FROM public.user_roles ur
                JOIN public.role_permissions rp ON rp.role_id = ur.role
                WHERE ur.user_id = v_user.id 
                  AND ur.is_active = TRUE 
                  AND rp.permission_id = p_required_permission
            ) THEN
                v_has_perm := TRUE;
            -- Fallback check role permissions via users.role
            ELSIF EXISTS (
                SELECT 1 
                FROM public.role_permissions rp
                WHERE rp.role_id = v_user.role 
                  AND rp.permission_id = p_required_permission
            ) THEN
                v_has_perm := TRUE;
            END IF;
        END IF;

        IF NOT v_has_perm THEN
            RETURN QUERY SELECT v_user.id, v_user.role, COALESCE(v_user.branch_id, 1::BIGINT), FALSE, 'PERMISSION_DENIED'::TEXT;
            RETURN;
        END IF;
    END IF;

    -- 6. Success: Return active user context
    RETURN QUERY SELECT v_user.id, v_user.role, COALESCE(v_user.branch_id, 1::BIGINT), TRUE, NULL::TEXT;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp;

CREATE OR REPLACE FUNCTION public.secure_get_customer_profile(
    p_session_token TEXT
)
RETURNS JSONB AS $$
DECLARE
    v_auth RECORD;
    v_user RECORD;
BEGIN
    -- Validate session token internally
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF NOT v_auth.is_valid THEN
        RETURN jsonb_build_object('success', false, 'error', v_auth.error_code);
    END IF;

    -- Fetch user profile filtering out credential/auth fields
    SELECT id, full_name, name, email, mobile, phone, role, created_at
    INTO v_user
    FROM public.users
    WHERE id = v_auth.user_id;

    IF v_user IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'USER_NOT_FOUND');
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'profile', jsonb_build_object(
            'id', v_user.id,
            'full_name', COALESCE(v_user.full_name, v_user.name),
            'name', COALESCE(v_user.full_name, v_user.name),
            'email', v_user.email,
            'mobile', COALESCE(v_user.mobile, v_user.phone),
            'phone', COALESCE(v_user.mobile, v_user.phone),
            'role', v_user.role,
            'created_at', v_user.created_at
        )
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp;

CREATE OR REPLACE FUNCTION public.secure_update_customer_profile(
    p_session_token TEXT,
    p_full_name TEXT
)
RETURNS JSONB AS $$
DECLARE
    v_auth RECORD;
    v_clean_name TEXT;
BEGIN
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF NOT v_auth.is_valid THEN
        RETURN jsonb_build_object('success', false, 'error', v_auth.error_code);
    END IF;

    v_clean_name := trim(p_full_name);
    IF v_clean_name IS NULL OR v_clean_name = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_NAME');
    END IF;

    UPDATE public.users
    SET full_name = v_clean_name,
        name = v_clean_name,
        updated_at = NOW()
    WHERE id = v_auth.user_id;

    RETURN jsonb_build_object('success', true, 'full_name', v_clean_name);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp;

CREATE OR REPLACE FUNCTION public.secure_get_customer_orders(
    p_session_token TEXT
)
RETURNS JSONB AS $$
DECLARE
    v_auth RECORD;
    v_user_phone TEXT;
    v_orders JSONB;
BEGIN
    -- Validate session token internally using Phase 3A session helper
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF NOT v_auth.is_valid THEN
        RETURN jsonb_build_object('success', false, 'error', v_auth.error_code);
    END IF;

    -- Resolve customer phone server-side
    SELECT COALESCE(mobile, phone) INTO v_user_phone
    FROM public.users
    WHERE id = v_auth.user_id;

    IF v_user_phone IS NULL OR v_user_phone = '' THEN
        RETURN jsonb_build_object('success', true, 'orders', '[]'::jsonb);
    END IF;

    -- Query orders bound to validated customer phone / user_id
    SELECT jsonb_agg(
        jsonb_build_object(
            'id', o.id,
            'order_number', o.id::text,
            'created_at', o.created_at,
            'status', o.status,
            'payment_status', o.payment_status,
            'payment_method', o.payment_method,
            'delivery_mode', o.delivery_mode,
            'subtotal', o.subtotal,
            'gst', o.gst,
            'delivery_fee', o.delivery_fee,
            'packing_charge', 0,
            'total', o.total,
            'items', (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'id', oi.id,
                        'product_name', oi.product_name,
                        'quantity', oi.quantity,
                        'unit_price', oi.price,
                        'price', oi.price,
                        'total_price', COALESCE(oi.total, oi.price * oi.quantity)
                    )
                )
                FROM public.order_items oi
                WHERE oi.order_id = o.id
            )
        ) ORDER BY o.id DESC
    ) INTO v_orders
    FROM public.orders o
    WHERE o.user_id = v_auth.user_id OR o.phone = v_user_phone;

    RETURN jsonb_build_object(
        'success', true,
        'orders', COALESCE(v_orders, '[]'::jsonb)
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp;

CREATE OR REPLACE FUNCTION public.secure_sync_pos_order(
    p_session_token TEXT,
    p_order JSONB,
    p_items JSONB DEFAULT '[]'::jsonb
)
RETURNS JSONB AS $$
DECLARE
    v_auth RECORD;
    v_offline_sync_id TEXT;
    v_order_number TEXT;
    v_existing_order RECORD;
    v_order_id BIGINT;
    v_subtotal NUMERIC;
    v_gst NUMERIC;
    v_delivery_fee NUMERIC;
    v_discount NUMERIC;
    v_service_charge NUMERIC;
    v_total NUMERIC;
    v_financial_locked BOOLEAN := FALSE; -- P0-A: settled financial snapshot is read-only for generic sync
    v_created_at TIMESTAMPTZ;
    v_updated_at TIMESTAMPTZ := NOW();
    v_status TEXT;
    v_payment_status TEXT;
    v_item_payload JSONB;
    v_synced_items JSONB := '[]'::jsonb;
    v_item_price NUMERIC;
    v_item_qty NUMERIC;
    v_item_total NUMERIC;
    v_item_id BIGINT;
    v_session_item_id TEXT;
    v_existing_item RECORD;
    v_allocated_item_id BIGINT;
    v_item_status TEXT;
    v_mode TEXT; -- 'MODE_A_OFFLINE', 'MODE_B_REMOTE_ADAPT', or 'MODE_C_TABLE_SESSION_SKELETON' (PASS 2K)
    v_table_id BIGINT; -- PASS 2K
    v_table_session_id BIGINT; -- PASS 2K
    v_is_table_scoped BOOLEAN; -- PASS 2K
    v_table RECORD; -- PASS 2K
    v_live_order_count INTEGER; -- PASS 2K
BEGIN
    -- 1. Validate caller session token internally
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF NOT v_auth.is_valid THEN
        RETURN jsonb_build_object('success', false, 'error', v_auth.error_code);
    END IF;

    -- 2. Enforce Role Authorization (POS internal roles ONLY including pos_staff - Reject customer/unauthorized)
    IF v_auth.role IS NULL OR lower(v_auth.role) IN ('customer', 'user', 'guest') OR lower(v_auth.role) NOT IN ('pos', 'pos_staff', 'cashier', 'staff', 'manager', 'admin', 'super_admin', 'staffadmin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'UNAUTHORIZED_ROLE');
    END IF;

    -- 3. Validate input order payload
    IF p_order IS NULL OR jsonb_typeof(p_order) <> 'object' THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_PAYLOAD');
    END IF;

    v_offline_sync_id := trim(p_order->>'offline_sync_id');
    IF (p_order->>'id') IS NOT NULL AND (p_order->>'id') ~ '^\d+$' THEN
        v_order_id := (p_order->>'id')::BIGINT;
    END IF;

    -- PASS 2K: table_id presence is the structural signal for a
    -- table/session-scoped dine-in sync (Pass 2I/2K Section E: gate on
    -- structural evidence already inside the row, never on a caller-supplied
    -- delivery_mode string, since this RPC's own ALLOWED_ORDER_FIELDS accepts
    -- delivery_mode as a generic passthrough and does not itself restrict it).
    v_table_id := CASE WHEN (p_order->>'table_id') ~ '^\d+$' THEN (p_order->>'table_id')::BIGINT ELSE NULL END;
    v_table_session_id := CASE WHEN (p_order->>'table_session_id') ~ '^\d+$' THEN (p_order->>'table_session_id')::BIGINT ELSE NULL END;
    v_is_table_scoped := v_table_id IS NOT NULL;

    -- Determine Order Entry Mode
    IF v_offline_sync_id IS NOT NULL AND v_offline_sync_id <> '' THEN
        v_mode := 'MODE_A_OFFLINE';
    ELSIF v_order_id IS NOT NULL THEN
        v_mode := 'MODE_B_REMOTE_ADAPT';
    ELSIF v_is_table_scoped AND v_table_session_id IS NOT NULL THEN
        -- PASS 2K: no offline_sync_id and no numeric id yet, but this is a
        -- table/session-scoped call -- resolve against the skeleton
        -- secure_start_table_session already created, below.
        v_mode := 'MODE_C_TABLE_SESSION_SKELETON';
    ELSE
        RETURN jsonb_build_object('success', false, 'error', 'MISSING_OFFLINE_SYNC_ID');
    END IF;

    -- 4. Mode-based Order Identification & Ownership Validation
    IF v_mode = 'MODE_A_OFFLINE' THEN
        SELECT * INTO v_existing_order FROM public.pos_orders WHERE offline_sync_id = v_offline_sync_id FOR UPDATE;
        -- Fallback check: if explicit numeric id was also provided and conflicts with offline_sync_id
        IF v_existing_order.id IS NULL AND v_order_id IS NOT NULL THEN
            SELECT * INTO v_existing_order FROM public.pos_orders WHERE id = v_order_id FOR UPDATE;
            IF v_existing_order.id IS NOT NULL AND v_existing_order.offline_sync_id IS NOT NULL AND v_existing_order.offline_sync_id <> v_offline_sync_id THEN
                RETURN jsonb_build_object('success', false, 'error', 'ORDER_CONFLICT');
            END IF;
        END IF;
    ELSIF v_mode = 'MODE_B_REMOTE_ADAPT' THEN
        SELECT * INTO v_existing_order FROM public.pos_orders WHERE id = v_order_id FOR UPDATE;
        IF v_existing_order.id IS NULL THEN
            -- Mode B MUST NOT create a new order if numeric ID lookup fails
            RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
        END IF;
    END IF;

    -- PASS 2L Section F correction: a table_id/table_session_id + active
    -- pos_tables verification must apply to EVERY table-scoped resolution,
    -- regardless of which mode found v_existing_order -- an offline_sync_id
    -- match (MODE_A) or a numeric id match (MODE_B) alone must never be
    -- sufficient to accept an order that actually belongs to a different
    -- table/session than the one in THIS payload. Without this, a stale or
    -- reused offline_sync_id/numeric id could let a table-scoped sync call
    -- silently update an order bound to a different table's session.
    IF v_is_table_scoped AND v_existing_order.id IS NOT NULL THEN
        IF v_existing_order.table_id IS DISTINCT FROM v_table_id THEN
            RETURN jsonb_build_object('success', false, 'error', 'TABLE_MISMATCH');
        END IF;
        IF v_table_session_id IS NOT NULL AND v_existing_order.table_session_id IS DISTINCT FROM v_table_session_id THEN
            RETURN jsonb_build_object('success', false, 'error', 'SESSION_MISMATCH');
        END IF;

        SELECT * INTO v_table FROM public.pos_tables WHERE id = v_table_id;
        IF v_table.id IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error', 'TABLE_MISMATCH');
        END IF;
        IF v_table.active_session_id IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error', 'SESSION_CLOSED');
        ELSIF v_existing_order.table_session_id IS DISTINCT FROM v_table.active_session_id THEN
            RETURN jsonb_build_object('success', false, 'error', 'SESSION_MISMATCH');
        END IF;
    END IF;

    -- PASS 2K Section D/E: table/session-scoped dine-in orders must resolve
    -- against the skeleton secure_start_table_session already created,
    -- rather than ever falling through to the INSERT branch in Section 7
    -- below. This covers MODE_C directly (no offline_sync_id sent yet) and
    -- also the case where a genuine offline_sync_id WAS sent but the
    -- skeleton itself still has offline_sync_id = NULL (MODE_A's lookup by
    -- offline_sync_id alone cannot find a NULL-keyed skeleton).
    IF v_is_table_scoped AND v_table_session_id IS NOT NULL AND v_existing_order.id IS NULL THEN
        SELECT * INTO v_table FROM public.pos_tables WHERE id = v_table_id;
        IF v_table.id IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error', 'TABLE_MISMATCH');
        END IF;
        IF v_table.active_session_id IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error', 'SESSION_CLOSED');
        ELSIF v_table.active_session_id IS DISTINCT FROM v_table_session_id THEN
            RETURN jsonb_build_object('success', false, 'error', 'SESSION_MISMATCH');
        END IF;

        -- Fail closed on ambiguity rather than silently picking a row: more
        -- than one live (non-finalized) order bound to the same
        -- table_session_id is a data-integrity problem this function must
        -- surface, not paper over. Canonical finalized-status set copied
        -- verbatim from secure_cancel_pos_order / secure_recover_orphaned_pos_table.
        SELECT count(*) INTO v_live_order_count
        FROM public.pos_orders
        WHERE table_session_id = v_table_session_id
          AND table_id = v_table_id
          AND lower(COALESCE(status, '')) NOT IN ('cancelled', 'voided', 'rejected', 'closed', 'settled', 'picked up', 'delivered');

        IF v_live_order_count > 1 THEN
            RETURN jsonb_build_object('success', false, 'error', 'AMBIGUOUS_ORDER_STATE');
        END IF;

        SELECT * INTO v_existing_order
        FROM public.pos_orders
        WHERE table_session_id = v_table_session_id
          AND table_id = v_table_id
          AND lower(COALESCE(status, '')) NOT IN ('cancelled', 'voided', 'rejected', 'closed', 'settled', 'picked up', 'delivered')
        FOR UPDATE;

        IF v_existing_order.id IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_YET_STARTED');
        END IF;

        -- Identity reconciliation (PASS 2K Section D): never silently
        -- overwrite a genuine existing offline_sync_id with a different
        -- value or with NULL; safely claim a still-NULL skeleton onto a
        -- genuine incoming value.
        IF v_existing_order.offline_sync_id IS NOT NULL
           AND v_offline_sync_id IS NOT NULL AND v_offline_sync_id <> ''
           AND v_existing_order.offline_sync_id <> v_offline_sync_id THEN
            RETURN jsonb_build_object('success', false, 'error', 'ORDER_IDENTITY_MISMATCH');
        END IF;
        IF v_existing_order.offline_sync_id IS NULL
           AND v_offline_sync_id IS NOT NULL AND v_offline_sync_id <> '' THEN
            v_existing_order.offline_sync_id := v_offline_sync_id;
        END IF;
    END IF;

    -- PASS 2K Section E: a table_id present in the payload marks this call as
    -- table/session-scoped dine-in. Such calls must NEVER reach the INSERT
    -- branch in Section 7 below -- the skeleton created by
    -- secure_start_table_session is the only legitimate origin of a
    -- table-bound pos_orders row. This is a safety net for the case where
    -- v_table_session_id was absent (malformed/legacy payload) so the block
    -- above never ran. Non-table-scoped behavior (no table_id in the
    -- payload) is completely unchanged by this pass -- proven unused in
    -- production today (Pass 2I/2J caller audit), but left fully intact.
    IF v_is_table_scoped AND v_existing_order.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_YET_STARTED');
    END IF;

    -- 5. Protect Finalized States, Settlement Escalation & Generic Cancellation Bypass Restriction
    v_payment_status := COALESCE(p_order->>'payment_status', 'Unpaid');
    v_status := COALESCE(p_order->>'status', 'OPEN');

    IF v_existing_order.id IS NOT NULL THEN
        -- Reopening finalized/paid/cancelled order is strictly FORBIDDEN
        IF lower(COALESCE(v_existing_order.payment_status, '')) = 'paid' OR lower(COALESCE(v_existing_order.status, '')) IN ('closed', 'settled', 'cancelled', 'voided') THEN
            v_payment_status := v_existing_order.payment_status;
            v_status := v_existing_order.status;
        END IF;
    END IF;

    -- Generic sync cannot escalate an unpaid order to Paid or CLOSED, nor can it authoritatively cancel an OPEN remote order
    IF (lower(v_payment_status) = 'paid' OR lower(v_status) IN ('closed', 'settled', 'cancelled', 'voided')) THEN
        IF v_existing_order.id IS NULL THEN
            -- Brand new offline order payload with status Cancelled/Voided: store initial remote order as OPEN
            -- Authoritative cancellation must occur via secure_cancel_pos_order
            IF lower(v_status) IN ('cancelled', 'voided') THEN
                v_status := 'OPEN';
            END IF;
            IF lower(v_payment_status) = 'paid' THEN
                v_payment_status := 'Unpaid';
            END IF;
        ELSIF lower(COALESCE(v_existing_order.payment_status, '')) <> 'paid' AND lower(COALESCE(v_existing_order.status, '')) NOT IN ('cancelled', 'voided') THEN
            -- Existing remote order is OPEN: Generic sync MUST NOT cancel or close it! Preserve remote open status.
            v_payment_status := 'Unpaid';
            IF lower(v_status) IN ('closed', 'settled', 'cancelled', 'voided') THEN
                v_status := v_existing_order.status;
            END IF;
        END IF;
    END IF;

    -- 5b. [QR STATUS AUTHORITY] An accepted QR order's lifecycle status is
    -- owned by secure_accept_qr_order (canonical 'OPEN', 20260929180000),
    -- not by a POS terminal's cached copy. 'Preparing' / 'Confirmed' are
    -- legacy QR-accept artifacts (pre-180000 acceptQrOrder local copies,
    -- and cancel-rollback copies of them) that are outside the POS dine-in
    -- lifecycle secure_cancel_pos_order accepts. Generic sync must not
    -- regress an existing QR_TABLE order to them; keep the cloud status.
    -- Scope is deliberately narrow: QR_TABLE orders only, those two values
    -- only -- normal POS orders and every other transition are unchanged.
    IF v_existing_order.id IS NOT NULL
       AND COALESCE(v_existing_order.order_source, '') = 'QR_TABLE'
       AND lower(COALESCE(v_status, '')) IN ('preparing', 'confirmed')
       AND lower(COALESCE(v_existing_order.status, '')) NOT IN ('preparing', 'confirmed') THEN
        v_status := v_existing_order.status;
    END IF;

    -- 6. Calculate & Validate Financial Totals
    -- [P0-A FINANCIAL SNAPSHOT] subtotal / gst / delivery_fee / total:
    --   * NEW order (INSERT): unchanged rules (absent -> 0, total derived).
    --   * EXISTING order whose financial settlement is final
    --     (payment_status 'Paid', or status 'Closed'/'Settled' -- the
    --     settled states secure_settle_pos_order writes): the stored
    --     snapshot is authoritative; generic sync never overwrites it, even
    --     with explicit values (stale terminals send 0 / client totals).
    --   * EXISTING open order: PATCH semantics -- a key ABSENT from p_order
    --     preserves the stored value (missing field != zero); a key PRESENT
    --     is processed with the previous rule (COALESCE(value, 0)).
    --   All other order fields, status/payment authority and SESSION_CLOSED
    --   handling above are unchanged.
    v_discount := COALESCE((p_order->>'coupon_discount')::NUMERIC, 0.00) + COALESCE((p_order->>'manual_discount_amount')::NUMERIC, 0.00);
    v_service_charge := COALESCE((p_order->>'service_charge_amount')::NUMERIC, 0.00);

    IF v_existing_order.id IS NULL THEN
        v_subtotal := COALESCE((p_order->>'subtotal')::NUMERIC, 0.00);
        v_gst := COALESCE((p_order->>'gst')::NUMERIC, 0.00);
        v_delivery_fee := COALESCE((p_order->>'delivery_fee')::NUMERIC, 0.00);
        v_total := COALESCE((p_order->>'total')::NUMERIC, GREATEST(0.00, v_subtotal + v_gst + v_delivery_fee + v_service_charge - v_discount));
    ELSE
        v_financial_locked := lower(COALESCE(v_existing_order.payment_status, '')) = 'paid'
                              OR lower(COALESCE(v_existing_order.status, '')) IN ('closed', 'settled');

        IF v_financial_locked THEN
            v_subtotal := v_existing_order.subtotal;
            v_gst := v_existing_order.gst;
            v_delivery_fee := v_existing_order.delivery_fee;
            v_total := v_existing_order.total;
        ELSE
            v_subtotal := CASE WHEN p_order ? 'subtotal' THEN COALESCE((p_order->>'subtotal')::NUMERIC, 0.00) ELSE v_existing_order.subtotal END;
            v_gst := CASE WHEN p_order ? 'gst' THEN COALESCE((p_order->>'gst')::NUMERIC, 0.00) ELSE v_existing_order.gst END;
            v_delivery_fee := CASE WHEN p_order ? 'delivery_fee' THEN COALESCE((p_order->>'delivery_fee')::NUMERIC, 0.00) ELSE v_existing_order.delivery_fee END;
            v_total := CASE WHEN p_order ? 'total'
                            THEN COALESCE((p_order->>'total')::NUMERIC, GREATEST(0.00, COALESCE(v_subtotal, 0.00) + COALESCE(v_gst, 0.00) + COALESCE(v_delivery_fee, 0.00) + v_service_charge - v_discount))
                            ELSE v_existing_order.total END;
        END IF;
    END IF;

    v_order_number := COALESCE(p_order->>'order_number', CASE WHEN v_existing_order.id IS NOT NULL THEN v_existing_order.order_number ELSE 'POS-' || nextval('public.shared_order_id_seq')::text END);

    -- 7. Execute Order Write (Update existing or Insert new with concurrent race protection)
    IF v_existing_order.id IS NOT NULL THEN
        v_order_id := v_existing_order.id;

        UPDATE public.pos_orders SET
            customer_name = COALESCE(p_order->>'customer_name', v_existing_order.customer_name),
            phone = COALESCE(p_order->>'phone', v_existing_order.phone),
            address = COALESCE(p_order->>'address', v_existing_order.address),
            landmark = COALESCE(p_order->>'landmark', v_existing_order.landmark),
            payment_method = COALESCE(p_order->>'payment_method', v_existing_order.payment_method),
            payment_status = v_payment_status,
            subtotal = v_subtotal,
            gst = v_gst,
            delivery_fee = v_delivery_fee,
            total = v_total,
            status = v_status,
            delivery_mode = COALESCE(p_order->>'delivery_mode', v_existing_order.delivery_mode),
            -- [P0-A2 ADJUSTMENT SNAPSHOT] coupon / manual discount / service
            -- charge: settled orders (v_financial_locked, same rule as P0-A)
            -- keep the stored values; open orders use PATCH semantics --
            -- absent key preserves, present key (including explicit JSON
            -- null) is processed exactly as before.
            coupon_code = CASE WHEN v_financial_locked THEN v_existing_order.coupon_code
                         WHEN p_order ? 'coupon_code' THEN p_order->>'coupon_code'
                         ELSE v_existing_order.coupon_code END,
            coupon_discount = CASE WHEN v_financial_locked THEN v_existing_order.coupon_discount
                         WHEN p_order ? 'coupon_discount' THEN COALESCE((p_order->>'coupon_discount')::NUMERIC, 0.00)
                         ELSE v_existing_order.coupon_discount END,
            notes = p_order->>'notes',
            manual_discount_type = CASE WHEN v_financial_locked THEN v_existing_order.manual_discount_type
                         WHEN p_order ? 'manual_discount_type' THEN p_order->>'manual_discount_type'
                         ELSE v_existing_order.manual_discount_type END,
            manual_discount_value = CASE WHEN v_financial_locked THEN v_existing_order.manual_discount_value
                         WHEN p_order ? 'manual_discount_value' THEN (p_order->>'manual_discount_value')::NUMERIC
                         ELSE v_existing_order.manual_discount_value END,
            manual_discount_amount = CASE WHEN v_financial_locked THEN v_existing_order.manual_discount_amount
                         WHEN p_order ? 'manual_discount_amount' THEN (p_order->>'manual_discount_amount')::NUMERIC
                         ELSE v_existing_order.manual_discount_amount END,
            manual_discount_percent = CASE WHEN v_financial_locked THEN v_existing_order.manual_discount_percent
                         WHEN p_order ? 'manual_discount_percent' THEN (p_order->>'manual_discount_percent')::NUMERIC
                         ELSE v_existing_order.manual_discount_percent END,
            service_charge_type = CASE WHEN v_financial_locked THEN v_existing_order.service_charge_type
                         WHEN p_order ? 'service_charge_type' THEN p_order->>'service_charge_type'
                         ELSE v_existing_order.service_charge_type END,
            service_charge_value = CASE WHEN v_financial_locked THEN v_existing_order.service_charge_value
                         WHEN p_order ? 'service_charge_value' THEN (p_order->>'service_charge_value')::NUMERIC
                         ELSE v_existing_order.service_charge_value END,
            service_charge_amount = CASE WHEN v_financial_locked THEN v_existing_order.service_charge_amount
                         WHEN p_order ? 'service_charge_amount' THEN (p_order->>'service_charge_amount')::NUMERIC
                         ELSE v_existing_order.service_charge_amount END,
            updated_at = v_updated_at,
            updated_by = v_auth.user_id::text,
            table_id = CASE WHEN (p_order->>'table_id') ~ '^\d+$' THEN (p_order->>'table_id')::BIGINT ELSE v_existing_order.table_id END,
            table_session_id = CASE WHEN (p_order->>'table_session_id') ~ '^\d+$' THEN (p_order->>'table_session_id')::BIGINT ELSE v_existing_order.table_session_id END,
            offline_sync_id = v_existing_order.offline_sync_id -- PASS 2K: persists any claim decided above; no-op for MODE_A/B
        WHERE id = v_order_id;
    ELSE
        v_created_at := COALESCE((p_order->>'created_at')::TIMESTAMPTZ, NOW());

        -- Exception handler to recover from concurrent order insertion races safely
        BEGIN
            INSERT INTO public.pos_orders (
                customer_name, phone, address, landmark, payment_method, payment_status,
                subtotal, gst, delivery_fee, total, status, created_at, delivery_mode,
                coupon_code, coupon_discount, notes, order_source, offline_sync_id,
                manual_discount_type, manual_discount_value, manual_discount_amount, manual_discount_percent,
                service_charge_type, service_charge_value, service_charge_amount,
                updated_at, updated_by, table_id, table_session_id, order_number
            ) VALUES (
                p_order->>'customer_name', p_order->>'phone', p_order->>'address', p_order->>'landmark',
                COALESCE(p_order->>'payment_method', 'Cash'), v_payment_status,
                v_subtotal, v_gst, v_delivery_fee, v_total, v_status, v_created_at, p_order->>'delivery_mode',
                p_order->>'coupon_code', COALESCE((p_order->>'coupon_discount')::NUMERIC, 0.00), p_order->>'notes',
                COALESCE(p_order->>'order_source', 'pos_dinein'), v_offline_sync_id,
                p_order->>'manual_discount_type', (p_order->>'manual_discount_value')::NUMERIC, (p_order->>'manual_discount_amount')::NUMERIC, (p_order->>'manual_discount_percent')::NUMERIC,
                p_order->>'service_charge_type', (p_order->>'service_charge_value')::NUMERIC, (p_order->>'service_charge_amount')::NUMERIC,
                v_updated_at, v_auth.user_id::text,
                CASE WHEN (p_order->>'table_id') ~ '^\d+$' THEN (p_order->>'table_id')::BIGINT ELSE NULL END,
                CASE WHEN (p_order->>'table_session_id') ~ '^\d+$' THEN (p_order->>'table_session_id')::BIGINT ELSE NULL END,
                v_order_number
            ) RETURNING id INTO v_order_id;
        EXCEPTION WHEN unique_violation THEN
            SELECT * INTO v_existing_order FROM public.pos_orders WHERE offline_sync_id = v_offline_sync_id FOR UPDATE;
            IF v_existing_order.id IS NOT NULL THEN
                v_order_id := v_existing_order.id;
            ELSE
                RETURN jsonb_build_object('success', false, 'error', 'SYNC_CONFLICT');
            END IF;
        END;
    END IF;

    -- 8. In-Place Item Synchronization with Session Item ID Hierarchy (ZERO DELETES)
    v_synced_items := '[]'::jsonb;

    IF jsonb_typeof(p_items) = 'array' AND jsonb_array_length(p_items) > 0 THEN
        FOR i IN 0..(jsonb_array_length(p_items) - 1) LOOP
            v_item_payload := p_items->i;
            v_session_item_id := trim(v_item_payload->>'session_item_id');
            IF v_session_item_id = '' THEN v_session_item_id := NULL; END IF;
            
            v_item_id := CASE WHEN (v_item_payload->>'id') ~ '^\d+$' THEN (v_item_payload->>'id')::BIGINT ELSE NULL END;
            v_item_price := COALESCE((v_item_payload->>'price')::NUMERIC, 0.00);
            v_item_qty := COALESCE((v_item_payload->>'quantity')::NUMERIC, (v_item_payload->>'qty')::NUMERIC, 1.00);
            v_item_total := COALESCE((v_item_payload->>'total')::NUMERIC, v_item_price * v_item_qty);

            v_existing_item := NULL;

            -- RESOLUTION CASE 1: Incoming Remote Item PK Provided
            IF v_item_id IS NOT NULL THEN
                SELECT * INTO v_existing_item FROM public.pos_order_items WHERE id = v_item_id;
                IF v_existing_item.id IS NULL THEN
                    RETURN jsonb_build_object('success', false, 'error', 'INVALID_ITEM');
                END IF;

                -- Ensure item belongs to THIS order
                IF v_existing_item.order_id <> v_order_id THEN
                    RETURN jsonb_build_object('success', false, 'error', 'ITEM_CONFLICT');
                END IF;

                -- Check identity conflict: If DB has a non-null session_item_id and incoming payload conflicts
                IF v_existing_item.session_item_id IS NOT NULL AND v_session_item_id IS NOT NULL AND v_existing_item.session_item_id <> v_session_item_id THEN
                    RETURN jsonb_build_object('success', false, 'error', 'ITEM_IDENTITY_CONFLICT');
                END IF;

                -- Adopt session_item_id if DB row currently has NULL
                IF v_existing_item.session_item_id IS NULL AND v_session_item_id IS NOT NULL THEN
                    IF EXISTS (SELECT 1 FROM public.pos_order_items WHERE order_id = v_order_id AND session_item_id = v_session_item_id AND id <> v_item_id) THEN
                        RETURN jsonb_build_object('success', false, 'error', 'ITEM_IDENTITY_CONFLICT');
                    END IF;
                ELSE
                    v_session_item_id := COALESCE(v_existing_item.session_item_id, v_session_item_id);
                END IF;

            -- RESOLUTION CASE 2: No Remote ID, session_item_id Provided (Lost-Response Retry Path)
            ELSIF v_session_item_id IS NOT NULL THEN
                SELECT * INTO v_existing_item FROM public.pos_order_items 
                WHERE order_id = v_order_id AND session_item_id = v_session_item_id;
            END IF;

            -- UPDATE or INSERT Branching
            IF v_existing_item.id IS NOT NULL THEN
                v_allocated_item_id := v_existing_item.id;

                -- Preserve line status if previously KOT_Sent, Rejected, or Cancelled unless payload explicitly updates
                v_item_status := COALESCE(v_item_payload->>'status', v_existing_item.status, 'Pending');
                IF v_existing_item.status IN ('KOT_Sent', 'Rejected', 'Cancelled') AND (v_item_payload->>'status') IS NULL THEN
                    v_item_status := v_existing_item.status;
                END IF;

                -- Execute IN-PLACE UPDATE
                UPDATE public.pos_order_items SET
                    session_item_id = COALESCE(v_existing_item.session_item_id, v_session_item_id),
                    product_id = CASE WHEN (v_item_payload->>'product_id') ~ '^\d+$' THEN (v_item_payload->>'product_id')::BIGINT ELSE v_existing_item.product_id END,
                    product_name = COALESCE(v_item_payload->>'product_name', v_item_payload->>'name', v_existing_item.product_name),
                    product_image = COALESCE(v_item_payload->>'product_image', v_existing_item.product_image),
                    variant_name = COALESCE(v_item_payload->>'variant_name', v_existing_item.variant_name),
                    addons = COALESCE(v_item_payload->>'addons', v_existing_item.addons),
                    quantity = v_item_qty::INTEGER,
                    price = v_item_price,
                    total = v_item_total,
                    item_discount_type = v_item_payload->>'item_discount_type',
                    item_discount_value = COALESCE((v_item_payload->>'item_discount_value')::NUMERIC, 0.00),
                    item_discount_amount = COALESCE((v_item_payload->>'item_discount_amount')::NUMERIC, 0.00),
                    item_discount_reason = v_item_payload->>'item_discount_reason',
                    item_final_price = COALESCE((v_item_payload->>'item_final_price')::NUMERIC, v_item_total),
                    status = v_item_status,
                    combo_snapshot = COALESCE(v_item_payload->'combo_snapshot', v_existing_item.combo_snapshot)
                WHERE id = v_allocated_item_id AND order_id = v_order_id;
            ELSE
                -- RESOLUTION CASE 3: NEW ITEM INSERT
                v_item_status := COALESCE(v_item_payload->>'status', 'Pending');

                BEGIN
                    INSERT INTO public.pos_order_items (
                        order_id, session_item_id, product_id, product_name, product_image, variant_name, addons,
                        quantity, price, total, item_discount_type, item_discount_value, item_discount_amount,
                        item_discount_reason, item_final_price, status, combo_snapshot
                    ) VALUES (
                        v_order_id,
                        v_session_item_id,
                        CASE WHEN (v_item_payload->>'product_id') ~ '^\d+$' THEN (v_item_payload->>'product_id')::BIGINT ELSE NULL END,
                        COALESCE(v_item_payload->>'product_name', v_item_payload->>'name', 'Item'),
                        v_item_payload->>'product_image',
                        v_item_payload->>'variant_name',
                        v_item_payload->>'addons',
                        v_item_qty::INTEGER,
                        v_item_price,
                        v_item_total,
                        v_item_payload->>'item_discount_type',
                        COALESCE((v_item_payload->>'item_discount_value')::NUMERIC, 0.00),
                        COALESCE((v_item_payload->>'item_discount_amount')::NUMERIC, 0.00),
                        v_item_payload->>'item_discount_reason',
                        COALESCE((v_item_payload->>'item_final_price')::NUMERIC, v_item_total),
                        v_item_status,
                        v_item_payload->'combo_snapshot'
                    ) RETURNING id INTO v_allocated_item_id;
                EXCEPTION WHEN unique_violation THEN
                    -- Concurrent duplicate insert race on (order_id, session_item_id); recover inserted item
                    IF v_session_item_id IS NOT NULL THEN
                        SELECT * INTO v_existing_item FROM public.pos_order_items 
                        WHERE order_id = v_order_id AND session_item_id = v_session_item_id;
                        IF v_existing_item.id IS NOT NULL THEN
                            v_allocated_item_id := v_existing_item.id;
                        ELSE
                            RETURN jsonb_build_object('success', false, 'error', 'SYNC_CONFLICT');
                        END IF;
                    ELSE
                        RETURN jsonb_build_object('success', false, 'error', 'SYNC_CONFLICT');
                    END IF;
                END;
            END IF;

            -- Append synced item to response payload with persistent session_item_id correlation
            v_synced_items := v_synced_items || jsonb_build_array(
                jsonb_build_object(
                    'id', v_allocated_item_id,
                    'session_item_id', v_session_item_id,
                    'product_id', CASE WHEN (v_item_payload->>'product_id') ~ '^\d+$' THEN (v_item_payload->>'product_id')::BIGINT ELSE NULL END,
                    'product_name', COALESCE(v_item_payload->>'product_name', v_item_payload->>'name', 'Item'),
                    'variant_name', v_item_payload->>'variant_name',
                    'quantity', v_item_qty::INTEGER,
                    'price', v_item_price,
                    'total', v_item_total,
                    'status', v_item_status
                )
            );
        END LOOP;
    END IF;

    -- If no items passed in payload, query current committed items for response
    IF jsonb_array_length(v_synced_items) = 0 THEN
        SELECT jsonb_agg(
            jsonb_build_object(
                'id', oi.id,
                'session_item_id', oi.session_item_id,
                'product_id', oi.product_id,
                'product_name', oi.product_name,
                'variant_name', oi.variant_name,
                'quantity', oi.quantity,
                'price', oi.price,
                'total', oi.total,
                'status', oi.status
            )
        ) INTO v_synced_items
        FROM public.pos_order_items oi
        WHERE oi.order_id = v_order_id;
    END IF;

    -- 9. Return Server-Committed Response Contract
    RETURN jsonb_build_object(
        'success', true,
        'order_id', v_order_id,
        'offline_sync_id', v_offline_sync_id,
        'order_number', v_order_number,
        'status', v_status,
        'payment_status', v_payment_status,
        'total', v_total,
        'updated_at', v_updated_at,
        'items', COALESCE(v_synced_items, '[]'::jsonb)
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp;

CREATE OR REPLACE FUNCTION public.secure_settle_pos_order(
    p_session_token TEXT,
    p_order_id BIGINT,
    p_settlement_key TEXT,
    p_payment JSONB DEFAULT '{}'::jsonb
)
RETURNS JSONB AS $$
DECLARE
    v_auth RECORD;
    v_master_order RECORD;
    v_table_row RECORD;
    v_settlement_key TEXT;
    v_payment_method TEXT;
    v_target_status TEXT;
    v_item_total NUMERIC := 0.00;
    v_total_item_discounts NUMERIC := 0.00;
    v_subtotal NUMERIC := 0.00;
    v_gst NUMERIC := 0.00;
    v_service_charge NUMERIC := 0.00;
    v_coupon_discount NUMERIC := 0.00;
    v_manual_discount NUMERIC := 0.00;
    v_total_discounts NUMERIC := 0.00;
    v_raw_grand_total NUMERIC := 0.00;
    v_grand_total NUMERIC := 0.00;
    v_round_off NUMERIC := 0.00;
    v_cash_paid NUMERIC := 0.00;
    v_upi_paid NUMERIC := 0.00;
    v_card_paid NUMERIC := 0.00;
    v_total_paid NUMERIC := 0.00;
    v_has_invalid_items BOOLEAN := FALSE;
BEGIN
    -- 1. Validate caller session token internally
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF v_auth.is_valid IS NOT TRUE THEN
        RETURN jsonb_build_object('success', false, 'error', COALESCE(v_auth.error_code, 'INVALID_SESSION'));
    END IF;

    -- 2. Enforce Role Authorization (POS internal roles ONLY - Reject customer/unauthorized)
    IF v_auth.role IS NULL OR lower(v_auth.role) IN ('customer', 'user', 'guest') OR lower(v_auth.role) NOT IN ('pos', 'cashier', 'staff', 'manager', 'admin', 'super_admin', 'staffadmin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'UNAUTHORIZED_ROLE');
    END IF;

    -- 3. Validate Inputs
    IF p_order_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'MISSING_ORDER_ID');
    END IF;

    IF p_payment IS NOT NULL AND jsonb_typeof(p_payment) <> 'object' THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_PAYMENT_PAYLOAD');
    END IF;

    v_settlement_key := trim(COALESCE(p_settlement_key, ''));
    IF v_settlement_key = '' OR length(v_settlement_key) > 255 THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_SETTLEMENT_KEY');
    END IF;

    -- 4. Lock Target Master Order FOR UPDATE (Prevent concurrent settlement races)
    SELECT * INTO v_master_order FROM public.pos_orders WHERE id = p_order_id FOR UPDATE;
    IF v_master_order.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
    END IF;

    -- 5. Idempotency Boundary: Same-Key Retry (Read-Only) vs Different-Key Settlement Conflict
    IF lower(COALESCE(v_master_order.payment_status, '')) = 'paid' OR lower(COALESCE(v_master_order.status, '')) IN ('closed', 'settled', 'picked up', 'delivered') THEN
        IF v_master_order.settlement_key IS NOT NULL AND v_master_order.settlement_key = v_settlement_key THEN
            -- Same-Key Lost-Response Replay (Read-Only Success - 0 Mutations / 0 Duplicates)
            RETURN jsonb_build_object(
                'success', true,
                'idempotent_replay', true,
                'order_id', v_master_order.id,
                'order_number', v_master_order.order_number,
                'status', v_master_order.status,
                'payment_status', v_master_order.payment_status,
                'payment_method', v_master_order.payment_method,
                'subtotal', v_master_order.subtotal,
                'gst', v_master_order.gst,
                'total', v_master_order.total,
                'table_id', v_master_order.table_id,
                'table_session_id', v_master_order.table_session_id,
                'settlement_key', v_master_order.settlement_key,
                'settled_at', v_master_order.updated_at
            );
        ELSE
            -- Order is already paid under a different settlement key
            RETURN jsonb_build_object('success', false, 'error', 'ORDER_ALREADY_SETTLED');
        END IF;
    END IF;

    -- 6. Validate Settleable Status
    IF lower(COALESCE(v_master_order.status, '')) IN ('cancelled', 'rejected', 'voided', 'deleted') THEN
        RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_SETTLEABLE');
    END IF;

    -- 7. Payment Method & Allocation Validation
    v_payment_method := trim(COALESCE(p_payment->>'payment_method', v_master_order.payment_method, 'Cash'));
    IF lower(v_payment_method) NOT IN ('cash', 'upi', 'card', 'split') THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_PAYMENT_METHOD');
    END IF;

    -- Normalize Payment Method Casing
    IF lower(v_payment_method) = 'cash' THEN v_payment_method := 'Cash';
    ELSIF lower(v_payment_method) = 'upi' THEN v_payment_method := 'UPI';
    ELSIF lower(v_payment_method) = 'card' THEN v_payment_method := 'Card';
    ELSIF lower(v_payment_method) = 'split' THEN v_payment_method := 'Split';
    END IF;

    -- 8. Quantity & Price Sanity Guard
    SELECT EXISTS (
        SELECT 1 FROM public.pos_order_items
        WHERE order_id = v_master_order.id
          AND lower(COALESCE(status, '')) NOT IN ('cancelled', 'rejected', 'voided')
          AND (quantity IS NULL OR quantity <= 0 OR price IS NULL OR price < 0 OR quantity > 10000)
    ) INTO v_has_invalid_items;

    IF v_has_invalid_items THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_ITEM_QUANTITY_OR_PRICE');
    END IF;

    -- 9. Compute Financial SSOT from pos_order_items snapshot
    SELECT
        COALESCE(SUM(COALESCE(price, 0) * COALESCE(quantity, 0)), 0.00),
        COALESCE(SUM(COALESCE(item_discount_amount, 0)), 0.00)
    INTO v_item_total, v_total_item_discounts
    FROM public.pos_order_items
    WHERE order_id = v_master_order.id
      AND lower(COALESCE(status, '')) NOT IN ('cancelled', 'rejected', 'voided');

    v_subtotal := GREATEST(0.00, v_item_total - v_total_item_discounts);
    v_gst := ROUND(v_subtotal * 0.05);

    v_service_charge := COALESCE(v_master_order.service_charge_amount, 0.00);
    v_coupon_discount := COALESCE(v_master_order.coupon_discount, 0.00);
    v_manual_discount := COALESCE(v_master_order.manual_discount_amount, 0.00);
    v_total_discounts := v_coupon_discount + v_manual_discount;

    v_raw_grand_total := GREATEST(0.00, v_subtotal + v_gst + v_service_charge - v_total_discounts);
    v_grand_total := ROUND(v_raw_grand_total);
    v_round_off := ROUND(v_grand_total - v_raw_grand_total, 2);

    -- 10. Validate Payment Allocation against Server Grand Total
    IF v_payment_method = 'Split' THEN
        v_cash_paid := GREATEST(0.00, COALESCE((p_payment->>'cash_amount')::NUMERIC, 0.00));
        v_upi_paid := GREATEST(0.00, COALESCE((p_payment->>'upi_amount')::NUMERIC, 0.00));
        v_card_paid := GREATEST(0.00, COALESCE((p_payment->>'card_amount')::NUMERIC, 0.00));
        v_total_paid := v_cash_paid + v_upi_paid + v_card_paid;

        IF (v_upi_paid + v_card_paid) > v_grand_total THEN
            RETURN jsonb_build_object('success', false, 'error', 'PAYMENT_MISMATCH', 'message', 'Non-cash payment allocation exceeds total');
        END IF;

        IF v_total_paid < v_grand_total THEN
            RETURN jsonb_build_object('success', false, 'error', 'PAYMENT_MISMATCH', 'required', v_grand_total, 'provided', v_total_paid);
        END IF;
    ELSE
        v_total_paid := GREATEST(0.00, COALESCE((p_payment->>'paid_amount')::NUMERIC, v_grand_total));
        IF v_total_paid < v_grand_total THEN
            RETURN jsonb_build_object('success', false, 'error', 'PAYMENT_MISMATCH', 'required', v_grand_total, 'provided', v_total_paid);
        END IF;
    END IF;

    -- 11. Table & Session Pre-Locking and Strict Ownership Validation (Dine-In)
    IF v_master_order.table_id IS NOT NULL THEN
        SELECT * INTO v_table_row FROM public.pos_tables WHERE id = v_master_order.table_id FOR UPDATE;

        IF v_table_row.id IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error', 'TABLE_SESSION_CONFLICT', 'message', 'Table row not found');
        END IF;

        IF v_table_row.active_order_id::text IS DISTINCT FROM v_master_order.id::text AND (
            v_master_order.table_session_id IS NULL OR
            v_table_row.active_session_id::text IS DISTINCT FROM v_master_order.table_session_id::text
        ) THEN
            RETURN jsonb_build_object('success', false, 'error', 'TABLE_SESSION_CONFLICT', 'message', 'Table ownership mismatch');
        END IF;
    END IF;

    -- 12. Determine Final Order Status
    IF lower(COALESCE(v_master_order.delivery_mode, 'dinein')) = 'takeaway' THEN
        v_target_status := 'Picked Up';
    ELSIF lower(COALESCE(v_master_order.delivery_mode, 'dinein')) = 'delivery' THEN
        v_target_status := 'Delivered';
    ELSE
        v_target_status := 'Closed';
    END IF;

    -- 13. Execute Atomic Master Order Settlement (Normalized unique_violation handling)
    BEGIN
        UPDATE public.pos_orders SET
            status = v_target_status,
            payment_status = 'Paid',
            payment_method = v_payment_method,
            settlement_key = v_settlement_key,
            subtotal = v_subtotal,
            gst = v_gst,
            total = v_grand_total,
            updated_at = NOW(),
            updated_by = v_auth.user_id::text
        WHERE id = v_master_order.id;
    EXCEPTION WHEN unique_violation THEN
        RETURN jsonb_build_object('success', false, 'error', 'SETTLEMENT_CONFLICT', 'message', 'Settlement key collision detected');
    END;

    -- 14. Sibling Session Order Zeroing & Lock (Dine-In Multi-Order Sessions)
    IF v_master_order.table_session_id IS NOT NULL THEN
        PERFORM id FROM public.pos_orders
        WHERE table_session_id = v_master_order.table_session_id
          AND id <> v_master_order.id
          AND lower(COALESCE(status, '')) NOT IN ('cancelled', 'rejected', 'voided', 'deleted')
        ORDER BY id ASC
        FOR UPDATE;

        UPDATE public.pos_orders SET
            status = v_target_status,
            payment_status = 'Paid',
            subtotal = 0.00,
            gst = 0.00,
            manual_discount_amount = 0.00,
            coupon_discount = 0.00,
            total = 0.00,
            updated_at = NOW(),
            updated_by = v_auth.user_id::text
        WHERE table_session_id = v_master_order.table_session_id
          AND id <> v_master_order.id
          AND lower(COALESCE(status, '')) NOT IN ('cancelled', 'rejected', 'voided', 'deleted');
    END IF;

    -- 15. Conditional Table Release & Session Closure (Dine-In)
    IF v_master_order.table_id IS NOT NULL THEN
        UPDATE public.pos_tables SET
            status = 'available',
            guests = 0,
            active_order_id = NULL,
            active_session_id = NULL
        WHERE id = v_table_row.id;

        IF v_master_order.table_session_id IS NOT NULL THEN
            PERFORM id FROM public.table_sessions
            WHERE id = v_master_order.table_session_id
               OR session_token = v_master_order.table_session_id::text
            FOR UPDATE;

            UPDATE public.table_sessions SET
                status = 'closed',
                payment_status = 'paid',
                closed_at = NOW()
            WHERE id = v_master_order.table_session_id
               OR session_token = v_master_order.table_session_id::text;
        END IF;

        INSERT INTO public.pos_table_notifications (
            table_id,
            table_number,
            session_id,
            type,
            status,
            created_at
        ) VALUES (
            v_table_row.id,
            COALESCE(v_table_row.table_number, 'Table ' || v_table_row.id::text),
            v_master_order.table_session_id,
            'payment_completed',
            'seen',
            NOW()
        );
    END IF;

    -- 15.5 Perform Ready Inventory Phase 1B Sales Deduction with Durable Failure Capture
    BEGIN
        PERFORM public._ready_inventory_deduct_pos_sale(v_master_order.id);
    EXCEPTION WHEN OTHERS THEN
        DECLARE
            v_err_code TEXT;
            v_err_msg TEXT;
            v_err_detail TEXT;
            v_err_hint TEXT;
            v_err_context TEXT;
        BEGIN
            GET STACKED DIAGNOSTICS
                v_err_code    = RETURNED_SQLSTATE,
                v_err_msg     = MESSAGE_TEXT,
                v_err_detail  = PG_EXCEPTION_DETAIL,
                v_err_hint    = PG_EXCEPTION_HINT,
                v_err_context = PG_EXCEPTION_CONTEXT;

            INSERT INTO public.ready_inventory_sale_failures (
                source_type, source_order_id, operation,
                error_code, error_message, error_detail, error_hint, error_context,
                retry_count, resolved, created_at, last_seen_at
            ) VALUES (
                'POS', v_master_order.id, 'SALE_DEDUCTION',
                v_err_code, v_err_msg, v_err_detail, v_err_hint, v_err_context,
                1, FALSE, now(), now()
            )
            ON CONFLICT (source_type, source_order_id, operation) WHERE resolved = FALSE
            DO UPDATE SET
                retry_count = ready_inventory_sale_failures.retry_count + 1,
                last_seen_at = now(),
                error_code = EXCLUDED.error_code,
                error_message = EXCLUDED.error_message,
                error_detail = EXCLUDED.error_detail,
                error_hint = EXCLUDED.error_hint,
                error_context = EXCLUDED.error_context;
        END;
    END;

    -- 16. Return Authoritative Settlement Response Envelope
    RETURN jsonb_build_object(
        'success', true,
        'idempotent_replay', false,
        'order_id', v_master_order.id,
        'order_number', v_master_order.order_number,
        'status', v_target_status,
        'payment_status', 'Paid',
        'payment_method', v_payment_method,
        'subtotal', v_subtotal,
        'gst', v_gst,
        'total', v_grand_total,
        'table_id', v_master_order.table_id,
        'table_session_id', v_master_order.table_session_id,
        'table_released', v_master_order.table_id IS NOT NULL,
        'settlement_key', v_settlement_key,
        'settled_at', NOW()
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp;

CREATE OR REPLACE FUNCTION public.secure_cancel_pos_order(
    p_session_token TEXT,
    p_order_id BIGINT,
    p_reason TEXT,
    p_cancel_key TEXT,
    p_action TEXT DEFAULT 'cancel'
)
RETURNS JSONB AS $$
DECLARE
    v_auth RECORD;
    v_master_order RECORD;
    v_table_row RECORD;
    v_cancel_key TEXT;
    v_reason TEXT;
    v_action TEXT;
    v_target_status TEXT;
    v_open_sibling_count INTEGER := 0;
    v_table_released BOOLEAN := FALSE;
    v_session_closed BOOLEAN := FALSE;
BEGIN
    -- 1. Validate caller session token internally
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF v_auth.is_valid IS NOT TRUE THEN
        RETURN jsonb_build_object('success', false, 'error', COALESCE(v_auth.error_code, 'INVALID_SESSION'));
    END IF;

    -- 2. Enforce Role Authorization (POS internal roles ONLY - Including pos_staff & staffadmin)
    IF v_auth.role IS NULL OR lower(v_auth.role) IN ('customer', 'user', 'guest') OR lower(v_auth.role) NOT IN ('pos', 'pos_staff', 'cashier', 'staff', 'manager', 'admin', 'super_admin', 'staffadmin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'UNAUTHORIZED_ROLE');
    END IF;

    -- 3. Validate Inputs
    IF p_order_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_ORDER_ID');
    END IF;

    v_cancel_key := trim(COALESCE(p_cancel_key, ''));
    IF v_cancel_key = '' OR length(v_cancel_key) > 255 THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_CANCEL_KEY');
    END IF;

    v_action := lower(trim(COALESCE(p_action, 'cancel')));
    IF v_action NOT IN ('cancel', 'void') THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_CANCEL_ACTION');
    END IF;

    v_target_status := CASE WHEN v_action = 'void' THEN 'Voided' ELSE 'Cancelled' END;

    -- Whitespace normalization and length validation on cancellation reason
    v_reason := trim(regexp_replace(COALESCE(p_reason, ''), '\s+', ' ', 'g'));
    IF v_reason = '' OR length(v_reason) < 3 OR length(v_reason) > 500 THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_CANCEL_REASON');
    END IF;

    -- 4. Lock Target Master Order FOR UPDATE (Step 1 of Lock Hierarchy)
    SELECT * INTO v_master_order FROM public.pos_orders WHERE id = p_order_id FOR UPDATE;
    IF v_master_order.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
    END IF;

    -- 5. Idempotency Boundary: Same-Key Retry (Read-Only) vs Different-Key Already-Cancelled Check
    IF lower(COALESCE(v_master_order.status, '')) IN ('cancelled', 'voided') THEN
        IF v_master_order.cancel_key IS NOT NULL AND v_master_order.cancel_key = v_cancel_key THEN
            -- Same-Key Lost-Response Replay (Read-Only Success - 0 Mutations / 0 Duplicates)
            RETURN jsonb_build_object(
                'success', true,
                'idempotent_replay', true,
                'order_id', v_master_order.id,
                'order_number', v_master_order.order_number,
                'status', v_master_order.status,
                'payment_status', v_master_order.payment_status,
                'cancel_key', v_master_order.cancel_key,
                'cancel_reason', v_master_order.cancel_reason,
                'table_id', v_master_order.table_id,
                'table_session_id', v_master_order.table_session_id,
                'cancelled_at', v_master_order.updated_at
            );
        ELSE
            -- Order is already cancelled under a different key (Preserve historical cancel_key & cancel_reason)
            RETURN jsonb_build_object(
                'success', true,
                'already_cancelled', true,
                'order_id', v_master_order.id,
                'order_number', v_master_order.order_number,
                'status', v_master_order.status,
                'payment_status', v_master_order.payment_status,
                'cancel_key', v_master_order.cancel_key,
                'cancel_reason', v_master_order.cancel_reason,
                'table_id', v_master_order.table_id,
                'table_session_id', v_master_order.table_session_id,
                'cancelled_at', v_master_order.updated_at
            );
        END IF;
    END IF;

    -- 6. Settlement Finality Invariant Check
    IF lower(COALESCE(v_master_order.payment_status, '')) = 'paid' OR lower(COALESCE(v_master_order.status, '')) IN ('closed', 'settled', 'picked up', 'delivered') THEN
        RETURN jsonb_build_object('success', false, 'error', 'ORDER_ALREADY_SETTLED');
    END IF;

    -- 7. Positive Allowed Source Status Validation
    IF lower(COALESCE(v_master_order.status, '')) NOT IN ('pending', 'submitted', 'cooking', 'ready', 'new', 'open', 'hold', 'waiting_confirmation', 'draft', 'completed') THEN
        RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_CANCELLABLE');
    END IF;

    -- 8. Lock Table, Siblings, and Session in Deterministic Hierarchy (Matching Settlement Lock Order)
    IF v_master_order.table_id IS NOT NULL THEN
        -- Step 2: Lock Table Row FOR UPDATE
        SELECT * INTO v_table_row FROM public.pos_tables WHERE id = v_master_order.table_id FOR UPDATE;

        IF v_table_row.id IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error', 'TABLE_SESSION_CONFLICT', 'message', 'Table row not found');
        END IF;

        -- Fail-Closed Table Ownership Check (Architecture B: Numeric ID, Session ID, or Canonical Offline Sync ID Match)
        IF NOT (
            (v_table_row.active_order_id IS NOT NULL AND v_table_row.active_order_id::text = v_master_order.id::text) OR
            (v_master_order.table_session_id IS NOT NULL AND v_table_row.active_session_id IS NOT NULL AND v_table_row.active_session_id::text = v_master_order.table_session_id::text) OR
            (v_master_order.offline_sync_id IS NOT NULL AND v_table_row.active_order_id IS NOT NULL AND v_table_row.active_order_id::text = v_master_order.offline_sync_id::text)
        ) THEN
            RETURN jsonb_build_object('success', false, 'error', 'TABLE_SESSION_CONFLICT', 'message', 'Table ownership mismatch');
        END IF;

        -- Step 3: Lock Open Sibling Orders in Deterministic ID Order (Scope: table_session_id when present)
        IF v_master_order.table_session_id IS NOT NULL THEN
            PERFORM id FROM public.pos_orders
            WHERE table_session_id = v_master_order.table_session_id
              AND id <> v_master_order.id
              AND lower(COALESCE(status, '')) NOT IN ('cancelled', 'voided', 'rejected', 'closed', 'settled', 'picked up', 'delivered')
            ORDER BY id ASC
            FOR UPDATE;

            SELECT COUNT(*)::integer INTO v_open_sibling_count
            FROM public.pos_orders
            WHERE table_session_id = v_master_order.table_session_id
              AND id <> v_master_order.id
              AND lower(COALESCE(status, '')) NOT IN ('cancelled', 'voided', 'rejected', 'closed', 'settled', 'picked up', 'delivered');
        ELSE
            SELECT COUNT(*)::integer INTO v_open_sibling_count
            FROM public.pos_orders
            WHERE table_id = v_master_order.table_id
              AND id <> v_master_order.id
              AND lower(COALESCE(status, '')) NOT IN ('cancelled', 'voided', 'rejected', 'closed', 'settled', 'picked up', 'delivered');
        END IF;

        -- Step 4: Lock Table Session FOR UPDATE if attached
        IF v_master_order.table_session_id IS NOT NULL THEN
            PERFORM id FROM public.table_sessions
            WHERE id = v_master_order.table_session_id
               OR session_token = v_master_order.table_session_id::text
            FOR UPDATE;
        END IF;
    END IF;

    -- 9. Execute Master Order Cancellation Write (Normalized unique_violation handling)
    -- NOTE: Outcome B Frozen Rule - 0 mutations on public.kot_corrections or KOT structures.
    -- Cloud database does not store per-KOT release batch baseline; net kitchen quantity derivation
    -- is not possible on server alone. Kitchen correction remains separate client/local workflow.
    BEGIN
        UPDATE public.pos_orders SET
            status = v_target_status,
            cancel_reason = v_reason,
            cancel_key = v_cancel_key,
            updated_at = NOW(),
            updated_by = v_auth.user_id::text
        WHERE id = v_master_order.id;
    EXCEPTION WHEN unique_violation THEN
        RETURN jsonb_build_object('success', false, 'error', 'CANCEL_CONFLICT', 'message', 'Cancel key already used by another order');
    END;

    -- 10. Conditional Table Release & Session Closure (iff 0 open siblings remain)
    IF v_master_order.table_id IS NOT NULL AND v_open_sibling_count = 0 THEN
        UPDATE public.pos_tables SET
            status = 'available',
            guests = 0,
            active_order_id = NULL,
            active_session_id = NULL
        WHERE id = v_table_row.id;
        v_table_released := TRUE;

        IF v_master_order.table_session_id IS NOT NULL THEN
            UPDATE public.table_sessions SET
                status = 'closed',
                closed_at = NOW()
            WHERE id = v_master_order.table_session_id
               OR session_token = v_master_order.table_session_id::text;
            v_session_closed := TRUE;
        END IF;

        INSERT INTO public.pos_table_notifications (
            table_id,
            table_number,
            session_id,
            type,
            status,
            created_at
        ) VALUES (
            v_table_row.id,
            COALESCE(v_table_row.table_number, 'Table ' || v_table_row.id::text),
            v_master_order.table_session_id,
            'order_cancelled',
            'seen',
            NOW()
        );
    END IF;

    -- 11. Return Authoritative Response Envelope
    RETURN jsonb_build_object(
        'success', true,
        'idempotent_replay', false,
        'order_id', v_master_order.id,
        'order_number', v_master_order.order_number,
        'status', v_target_status,
        'payment_status', COALESCE(v_master_order.payment_status, 'Unpaid'),
        'cancel_key', v_cancel_key,
        'cancel_reason', v_reason,
        'table_id', v_master_order.table_id,
        'table_session_id', v_master_order.table_session_id,
        'table_released', v_table_released,
        'session_closed', v_session_closed,
        'cancelled_at', NOW()
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp;

CREATE OR REPLACE FUNCTION public.secure_force_reset_table(
    p_session_token TEXT,
    p_table_id BIGINT,
    p_reset_key TEXT,
    p_reason TEXT DEFAULT 'Force Reset via POS Table Management'
)
RETURNS JSONB AS $$
DECLARE
    v_session RECORD;
    v_user RECORD;
    v_table RECORD;
    v_cancelled_count INT := 0;
    v_already_logged RECORD;
BEGIN
    -- 1. Validate inputs
    IF p_session_token IS NULL OR TRIM(p_session_token) = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Session token is required.');
    END IF;

    IF p_table_id IS NULL OR p_table_id <= 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'Valid table ID is required.');
    END IF;

    IF p_reset_key IS NULL OR TRIM(p_reset_key) = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Reset key is required.');
    END IF;

    IF p_reason IS NULL OR TRIM(p_reason) = '' THEN
        p_reason := 'Force Reset via POS Table Management';
    END IF;

    -- 2. Validate Session & User Role
    SELECT * INTO v_session 
    FROM public.active_sessions 
    WHERE token = p_session_token AND expires_at > NOW() 
    LIMIT 1;

    IF v_session IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Session expired or invalid.');
    END IF;

    SELECT * INTO v_user 
    FROM public.users 
    WHERE id = v_session.user_id 
    LIMIT 1;

    IF v_user IS NULL OR v_user.role NOT IN ('super_admin', 'admin', 'manager', 'staff_admin', 'pos_staff') THEN
        RETURN jsonb_build_object('success', false, 'error', 'Unauthorized to execute table force reset.');
    END IF;

    -- 3. Idempotency Check via system_audit_logs reset_key
    SELECT * INTO v_already_logged
    FROM public.system_audit_logs
    WHERE action = 'force_reset_table'
      AND (details::jsonb)->>'reset_key' = p_reset_key
    LIMIT 1;

    IF v_already_logged IS NOT NULL THEN
        RETURN jsonb_build_object(
            'success', true,
            'idempotent_replay', true,
            'table_id', p_table_id,
            'message', 'Force reset already executed for this reset_key.'
        );
    END IF;

    -- 4. Lock Target Table
    SELECT * INTO v_table
    FROM public.pos_tables
    WHERE id = p_table_id
    FOR UPDATE;

    IF v_table IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Table not found.');
    END IF;

    -- 5. Cancel Open Unbilled Orders attached to this Table ID or Table Name
    -- Financial Finality Safety Gate: NEVER mutate Settled, Paid, Closed, Refunded, or Voided orders to Cancelled!
    WITH open_orders AS (
        SELECT id
        FROM public.pos_orders
        WHERE (table_id = p_table_id OR (v_table.name IS NOT NULL AND LOWER(address) LIKE '%' || LOWER(v_table.name) || '%'))
          AND UPPER(status) IN ('OPEN', 'PENDING', 'ACCEPTED', 'PREPARING', 'READY', 'CONFIRMED')
        FOR UPDATE
    ),
    updated_orders AS (
        UPDATE public.pos_orders SET
            status = 'Cancelled',
            notes = 'FORCE RESET: ' || p_reason
        WHERE id IN (SELECT id FROM open_orders)
        RETURNING id
    )
    SELECT COUNT(*) INTO v_cancelled_count FROM updated_orders;

    -- 6. Close Active Table Session if present
    IF v_table.active_session_id IS NOT NULL THEN
        UPDATE public.table_sessions SET
            status = 'closed',
            closed_at = NOW()
        WHERE (id::text = v_table.active_session_id OR session_token = v_table.active_session_id)
          AND status <> 'closed';
    END IF;

    -- 7. Reset Table State to Available
    UPDATE public.pos_tables SET
        status = 'available',
        guests = 0,
        active_order_id = NULL,
        active_session_id = NULL,
        merged_with = NULL
    WHERE id = p_table_id;

    -- 8. Record Security Audit Log
    INSERT INTO public.system_audit_logs (
        user_name,
        user_role,
        action,
        device,
        details
    ) VALUES (
        v_user.full_name,
        v_user.role,
        'force_reset_table',
        v_session.device,
        jsonb_build_object(
            'table_id', p_table_id,
            'table_name', v_table.name,
            'reset_key', p_reset_key,
            'reason', p_reason,
            'orders_cancelled', v_cancelled_count,
            'timestamp', NOW()
        )
    );

    RETURN jsonb_build_object(
        'success', true,
        'table_id', p_table_id,
        'orders_cancelled', v_cancelled_count
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.secure_void_table_session(
    p_session_token TEXT,
    p_table_id BIGINT,
    p_table_session_id TEXT,
    p_void_key TEXT,
    p_reason TEXT DEFAULT 'Consolidated Table Session Void'
)
RETURNS JSONB AS $$
DECLARE
    v_session RECORD;
    v_user RECORD;
    v_table RECORD;
    v_table_sess RECORD;
    v_voided_count INT := 0;
    v_already_logged RECORD;
    v_settled_count INT := 0;
BEGIN
    -- 1. Validate Input Parameters
    IF p_session_token IS NULL OR TRIM(p_session_token) = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_TOKEN', 'message', 'Session token is required.');
    END IF;

    IF p_table_id IS NULL OR p_table_id <= 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_TABLE', 'message', 'Valid table ID is required.');
    END IF;

    IF p_table_session_id IS NULL OR TRIM(p_table_session_id) = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_SESSION_ID', 'message', 'Table session ID is required.');
    END IF;

    IF p_void_key IS NULL OR TRIM(p_void_key) = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_VOID_KEY', 'message', 'Void key is required.');
    END IF;

    IF p_reason IS NULL OR TRIM(p_reason) = '' THEN
        p_reason := 'Consolidated Table Session Void';
    END IF;

    -- 2. Validate Session & User Role
    SELECT * INTO v_session 
    FROM public.active_sessions 
    WHERE token = p_session_token AND expires_at > NOW() 
    LIMIT 1;

    IF v_session IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'EXPIRED_SESSION', 'message', 'Session expired or invalid.');
    END IF;

    SELECT * INTO v_user 
    FROM public.users 
    WHERE id = v_session.user_id 
    LIMIT 1;

    IF v_user IS NULL OR v_user.role NOT IN ('super_admin', 'admin', 'manager', 'staff_admin', 'pos_staff') THEN
        RETURN jsonb_build_object('success', false, 'error', 'UNAUTHORIZED_ROLE', 'message', 'Unauthorized to void table session.');
    END IF;

    -- 3. Idempotency Check via system_audit_logs void_key
    SELECT * INTO v_already_logged
    FROM public.system_audit_logs
    WHERE action = 'void_table_session'
      AND details->>'void_key' = p_void_key
    LIMIT 1;

    IF FOUND THEN
        RETURN jsonb_build_object(
            'success', true,
            'idempotent_replay', true,
            'table_id', p_table_id,
            'session_id', p_table_session_id,
            'message', 'Session void already executed for this void_key.'
        );
    END IF;

    -- 4. Lock Target Table & Verify Ownership
    SELECT * INTO v_table
    FROM public.pos_tables
    WHERE id = p_table_id
    FOR UPDATE;

    IF v_table IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'TABLE_NOT_FOUND', 'message', 'Table not found.');
    END IF;

    -- Verify table session exists and belongs to table
    SELECT * INTO v_table_sess
    FROM public.table_sessions
    WHERE (id::text = p_table_session_id OR session_token = p_table_session_id)
    FOR UPDATE;

    IF v_table_sess IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'SESSION_NOT_FOUND', 'message', 'Table session not found.');
    END IF;

    -- Cross-Table Session Ownership Guard
    IF v_table_sess.table_id IS NOT NULL AND v_table_sess.table_id <> p_table_id THEN
        RETURN jsonb_build_object('success', false, 'error', 'CROSS_TABLE_SESSION_CONFLICT', 'message', 'Session does not belong to specified table.');
    END IF;

    -- Historical/Stale Session Check: session must either be current active session or match session_id
    IF v_table.active_session_id IS NOT NULL 
       AND v_table.active_session_id::text <> p_table_session_id 
       AND (v_table_sess.session_token IS NULL OR v_table.active_session_id::text <> v_table_sess.session_token)
       AND (v_table.active_session_id::text <> v_table_sess.id::text) THEN
        RETURN jsonb_build_object('success', false, 'error', 'STALE_SESSION_CONFLICT', 'message', 'Session is not the current active session for this table.');
    END IF;

    -- 5. Financial Finality Safety Gate:
    -- If ANY participating order in this table session is Settled, Paid, Closed, or Refunded, FAIL ENTIRE VOID!
    SELECT COUNT(*) INTO v_settled_count
    FROM public.pos_orders
    WHERE (table_session_id::text = p_table_session_id 
           OR table_session_id::text = v_table_sess.id::text
           OR (v_table_sess.session_token IS NOT NULL AND table_session_id::text = v_table_sess.session_token)
           OR (table_session_id IS NULL AND table_id = p_table_id))
      AND (
        UPPER(status) IN ('SETTLED', 'PAID', 'CLOSED', 'REFUNDED')
        OR UPPER(payment_status) = 'PAID'
      );

    IF v_settled_count > 0 THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'ORDER_ALREADY_SETTLED',
            'message', 'Cannot void session containing settled or paid orders.'
        );
    END IF;

    -- 6. Lock and Void All Open Participating Orders in Session
    WITH open_orders AS (
        SELECT id
        FROM public.pos_orders
        WHERE (table_session_id::text = p_table_session_id 
               OR table_session_id::text = v_table_sess.id::text
               OR (v_table_sess.session_token IS NOT NULL AND table_session_id::text = v_table_sess.session_token)
               OR (table_session_id IS NULL AND table_id = p_table_id))
          AND UPPER(status) IN ('OPEN', 'PENDING', 'ACCEPTED', 'PREPARING', 'READY', 'CONFIRMED')
        FOR UPDATE
    ),
    voided_orders AS (
        UPDATE public.pos_orders SET
            status = 'Voided',
            notes = COALESCE(notes, '') || ' | SESSION VOID: ' || p_reason
        WHERE id IN (SELECT id FROM open_orders)
        RETURNING id
    )
    SELECT COUNT(*) INTO v_voided_count FROM voided_orders;

    -- 7. Close Table Session Atomically
    UPDATE public.table_sessions SET
        status = 'closed',
        closed_at = NOW()
    WHERE (id::text = p_table_session_id OR session_token = p_table_session_id OR id = v_table_sess.id)
      AND status <> 'closed';

    -- 8. Release Table to Available State
    UPDATE public.pos_tables SET
        status = 'available',
        guests = 0,
        active_order_id = NULL,
        active_session_id = NULL,
        merged_with = NULL
    WHERE id = p_table_id;

    -- 9. Record Security Audit Log
    INSERT INTO public.system_audit_logs (
        user_name,
        user_role,
        action,
        device,
        details
    ) VALUES (
        v_user.full_name,
        v_user.role,
        'void_table_session',
        v_session.device,
        jsonb_build_object(
            'table_id', p_table_id,
            'table_name', v_table.name,
            'session_id', p_table_session_id,
            'void_key', p_void_key,
            'reason', p_reason,
            'orders_voided', v_voided_count,
            'timestamp', NOW()
        )
    );

    RETURN jsonb_build_object(
        'success', true,
        'table_id', p_table_id,
        'session_id', p_table_session_id,
        'orders_voided', v_voided_count
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.secure_reject_website_order(
    p_session_token TEXT,
    p_order_id BIGINT,
    p_rejection_key TEXT,
    p_reason TEXT DEFAULT 'Not specified'
)
RETURNS JSONB AS $$
DECLARE
    v_session RECORD;
    v_user RECORD;
    v_order RECORD;
    v_already_logged RECORD;
    v_clean_reason TEXT;
    v_payment_status TEXT;
    v_curr_status TEXT;
BEGIN
    -- 1. Validate Input Parameters
    IF p_session_token IS NULL OR TRIM(p_session_token) = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_TOKEN', 'message', 'Session token is required.');
    END IF;

    IF p_order_id IS NULL OR p_order_id <= 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_ORDER_ID', 'message', 'Valid numeric order ID is required.');
    END IF;

    IF p_rejection_key IS NULL OR TRIM(p_rejection_key) = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_REJECTION_KEY', 'message', 'Rejection key is required.');
    END IF;

    v_clean_reason := TRIM(COALESCE(p_reason, ''));
    IF v_clean_reason = '' THEN
        v_clean_reason := 'Not specified';
    END IF;
    IF LENGTH(v_clean_reason) > 500 THEN
        v_clean_reason := SUBSTRING(v_clean_reason FROM 1 FOR 500);
    END IF;

    -- 2. Validate Staff Session & Role
    SELECT * INTO v_session 
    FROM public.active_sessions 
    WHERE token = p_session_token AND expires_at > NOW() 
    LIMIT 1;

    IF v_session IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'EXPIRED_SESSION', 'message', 'Session expired or invalid.');
    END IF;

    SELECT * INTO v_user 
    FROM public.users 
    WHERE id = v_session.user_id 
    LIMIT 1;

    IF v_user IS NULL OR v_user.role NOT IN ('super_admin', 'admin', 'manager', 'staff_admin', 'pos_staff', 'kitchen_staff') THEN
        RETURN jsonb_build_object('success', false, 'error', 'UNAUTHORIZED_ROLE', 'message', 'Unauthorized to reject website order.');
    END IF;

    -- 3. Idempotency Check via system_audit_logs rejection_key
    SELECT * INTO v_already_logged
    FROM public.system_audit_logs
    WHERE action = 'reject_website_order'
      AND details->>'rejection_key' = p_rejection_key
    LIMIT 1;

    IF FOUND THEN
        RETURN jsonb_build_object(
            'success', true,
            'idempotent_replay', true,
            'order_id', p_order_id,
            'status', 'REJECTED',
            'message', 'Website order rejection already executed for this rejection_key.'
        );
    END IF;

    -- 4. Lock Target Order in public.orders
    SELECT * INTO v_order
    FROM public.orders
    WHERE id = p_order_id
    FOR UPDATE;

    IF v_order IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND', 'message', 'Target website order not found.');
    END IF;

    v_curr_status := UPPER(COALESCE(v_order.status, v_order.order_status, ''));

    -- Check if already rejected or cancelled with another key
    IF v_curr_status IN ('REJECTED', 'CANCELLED') THEN
        RETURN jsonb_build_object(
            'success', true,
            'already_rejected', true,
            'order_id', p_order_id,
            'status', v_curr_status,
            'message', 'Order has already been rejected/cancelled.'
        );
    END IF;

    -- Check if order has already been accepted / preparing / delivered
    IF v_curr_status IN ('PREPARING', 'ACCEPTED', 'OUT_FOR_DELIVERY', 'DELIVERED', 'COMPLETED') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'ORDER_ALREADY_ACCEPTED',
            'message', 'Order has already been accepted/preparing and cannot be rejected.'
        );
    END IF;

    -- 5. Financial Finality Gate: Check payment status
    v_payment_status := UPPER(COALESCE(v_order.payment_status, 'UNPAID'));
    IF v_payment_status IN ('SUCCESS', 'PAID', 'COMPLETED') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'PAYMENT_REQUIRES_REFUND',
            'message', 'Paid/captured online orders cannot be rejected without an explicit refund workflow.'
        );
    END IF;

    -- 6. Execute Rejection Update on public.orders (using cancel_reason TEXT column)
    UPDATE public.orders
    SET 
        status = 'REJECTED',
        order_status = 'REJECTED',
        cancel_reason = v_clean_reason
    WHERE id = p_order_id;

    -- 7. Audit Log Entry
    INSERT INTO public.system_audit_logs (
        user_name,
        user_role,
        action,
        device,
        details
    ) VALUES (
        COALESCE(v_user.full_name, 'Staff'),
        v_user.role,
        'reject_website_order',
        COALESCE(v_session.device, 'POS Terminal'),
        jsonb_build_object(
            'order_id', p_order_id,
            'rejection_key', p_rejection_key,
            'reason', v_clean_reason,
            'previous_status', v_curr_status,
            'payment_status', v_payment_status
        )
    );

    RETURN jsonb_build_object(
        'success', true,
        'order_id', p_order_id,
        'status', 'REJECTED',
        'message', 'Website order rejected successfully.'
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp;

CREATE OR REPLACE FUNCTION public.secure_cancel_delivery_order(
    p_session_token TEXT,
    p_delivery_order_id BIGINT,
    p_cancel_key TEXT,
    p_reason TEXT DEFAULT 'Not specified'
)
RETURNS JSONB AS $$
DECLARE
    v_session RECORD;
    v_user RECORD;
    v_order RECORD;
    v_already_logged RECORD;
    v_clean_reason TEXT;
    v_payment_status TEXT;
    v_curr_status TEXT;
    v_user_role_lower TEXT;
BEGIN
    -- 1. Validate Input Parameters
    IF p_session_token IS NULL OR TRIM(p_session_token) = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_TOKEN', 'message', 'Session token is required.');
    END IF;

    IF p_delivery_order_id IS NULL OR p_delivery_order_id <= 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_ORDER_ID', 'message', 'Valid numeric delivery order ID is required.');
    END IF;

    IF p_cancel_key IS NULL OR TRIM(p_cancel_key) = '' OR LENGTH(TRIM(p_cancel_key)) < 8 OR LENGTH(TRIM(p_cancel_key)) > 128 THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_CANCEL_KEY', 'message', 'Cancel key must be between 8 and 128 characters.');
    END IF;

    v_clean_reason := TRIM(COALESCE(p_reason, ''));
    IF v_clean_reason = '' THEN
        v_clean_reason := 'Not specified';
    END IF;
    IF LENGTH(v_clean_reason) > 500 THEN
        v_clean_reason := SUBSTRING(v_clean_reason FROM 1 FOR 500);
    END IF;

    -- 2. Validate Active Staff Session & Role (Strict Authorized Roles Only: super_admin, admin, manager, staff_admin, pos_staff, kitchen_staff)
    SELECT * INTO v_session 
    FROM public.active_sessions 
    WHERE token = p_session_token AND expires_at > NOW() 
    LIMIT 1;

    IF v_session IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'EXPIRED_SESSION', 'message', 'Session expired or invalid.');
    END IF;

    SELECT * INTO v_user 
    FROM public.users 
    WHERE id = v_session.user_id 
    LIMIT 1;

    v_user_role_lower := LOWER(TRIM(COALESCE(v_user.role, '')));

    IF v_user IS NULL OR v_user_role_lower NOT IN ('super_admin', 'admin', 'manager', 'staff_admin', 'pos_staff', 'kitchen_staff') THEN
        RETURN jsonb_build_object('success', false, 'error', 'UNAUTHORIZED_ROLE', 'message', 'Unauthorized to cancel delivery order.');
    END IF;

    -- 3. Idempotency Check via system_audit_logs cancel_key
    SELECT * INTO v_already_logged
    FROM public.system_audit_logs
    WHERE action = 'cancel_delivery_order'
      AND details->>'cancel_key' = p_cancel_key
    LIMIT 1;

    IF FOUND THEN
        RETURN jsonb_build_object(
            'success', true,
            'idempotent_replay', true,
            'delivery_order_id', p_delivery_order_id,
            'status', 'Cancelled',
            'message', 'Delivery order cancellation already executed for this cancel_key.'
        );
    END IF;

    -- 4. Lock Target Delivery Order in public.delivery_orders
    SELECT * INTO v_order
    FROM public.delivery_orders
    WHERE id = p_delivery_order_id
    FOR UPDATE;

    IF v_order IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND', 'message', 'Target delivery order not found.');
    END IF;

    v_curr_status := UPPER(TRIM(COALESCE(v_order.status, 'NEW')));

    -- Check if already cancelled
    IF v_curr_status = 'CANCELLED' THEN
        RETURN jsonb_build_object(
            'success', true,
            'already_cancelled', true,
            'delivery_order_id', p_delivery_order_id,
            'status', 'Cancelled',
            'message', 'Delivery order has already been cancelled.'
        );
    END IF;

    -- Check if order has already been delivered or completed
    IF v_curr_status IN ('DELIVERED', 'PICKED UP', 'COMPLETED') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'ORDER_ALREADY_DELIVERED',
            'message', 'Delivery order has already been delivered/completed and cannot be cancelled.'
        );
    END IF;

    -- Verify allowed status transitions (New, Pending, Accepted, Preparing, Ready, Out for Delivery)
    IF v_curr_status NOT IN ('NEW', 'PENDING', 'ACCEPTED', 'PREPARING', 'READY', 'OUT FOR DELIVERY') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'INVALID_STATE_TRANSITION',
            'message', 'Order status cannot transition to Cancelled.'
        );
    END IF;

    -- 5. Financial Finality Gate: Check payment status
    v_payment_status := UPPER(TRIM(COALESCE(v_order.payment_status, 'UNPAID')));
    IF v_payment_status IN ('SUCCESS', 'PAID', 'CAPTURED', 'COMPLETED') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'PAYMENT_REQUIRES_REFUND',
            'message', 'Paid/captured delivery orders cannot be cancelled without an explicit refund workflow.'
        );
    END IF;

    -- 6. Execute Cancellation Update on public.delivery_orders (clear rider_id if assigned)
    UPDATE public.delivery_orders
    SET 
        status = 'Cancelled',
        cancel_reason = v_clean_reason,
        rider_id = NULL,
        updated_at = NOW(),
        updated_by = COALESCE(v_user.name, 'Staff') || ' (' || COALESCE(v_user.role, 'Staff') || ')'
    WHERE id = p_delivery_order_id;

    -- 7. Audit History Entry in public.delivery_order_status_history
    INSERT INTO public.delivery_order_status_history (
        order_id,
        status,
        updated_at,
        updated_by
    ) VALUES (
        p_delivery_order_id,
        'Cancelled',
        NOW(),
        COALESCE(v_user.name, 'Staff') || ' [Key:' || p_cancel_key || '] Reason: ' || v_clean_reason
    );

    -- 8. Audit Log Entry in public.system_audit_logs
    INSERT INTO public.system_audit_logs (
        user_name,
        user_role,
        action,
        device,
        details
    ) VALUES (
        COALESCE(v_user.name, 'Staff'),
        COALESCE(v_user.role, 'Staff'),
        'cancel_delivery_order',
        COALESCE(v_session.device, 'POS Terminal'),
        jsonb_build_object(
            'delivery_order_id', p_delivery_order_id,
            'cancel_key', p_cancel_key,
            'reason', v_clean_reason,
            'previous_status', v_curr_status,
            'payment_status', v_payment_status
        )
    );

    RETURN jsonb_build_object(
        'success', true,
        'delivery_order_id', p_delivery_order_id,
        'status', 'Cancelled',
        'message', 'Delivery order cancelled successfully.'
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp;

CREATE OR REPLACE FUNCTION public.secure_record_manual_pos_refund(
    p_session_token TEXT,
    p_pos_order_id BIGINT,
    p_refund_key TEXT,
    p_refund_method TEXT,
    p_reason TEXT,
    p_approval_token TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_auth RECORD;
    v_approval_auth RECORD;
    v_approver_id BIGINT;
    v_refund_key TEXT;
    v_norm_method TEXT;
    v_reason TEXT;
    v_pos_order RECORD;
    v_existing_key_refund RECORD;
    v_existing_active_refund RECORD;
    v_orig_pay_status TEXT;
    v_orig_pay_method TEXT;
    v_orig_order_status TEXT;
    v_refund_amount NUMERIC(10,2);
    v_refund_id BIGINT;
    v_user RECORD;
BEGIN
    -- 1. Validate Session Token (Phase 3A Session Helper)
    SELECT * INTO v_auth
    FROM public.validate_active_session_internal(p_session_token, NULL);

    IF v_auth.is_valid IS NOT TRUE THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'UNAUTHORIZED',
            'error', COALESCE(v_auth.error_code, 'INVALID_SESSION')
        );
    END IF;

    -- Enforce Allowed Caller Roles
    IF v_auth.role IS NULL OR lower(v_auth.role) IN ('customer', 'user', 'guest') OR lower(v_auth.role) NOT IN ('super_admin', 'admin', 'manager', 'staff_admin', 'staffadmin', 'pos_staff', 'staff', 'cashier', 'pos') THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'UNAUTHORIZED',
            'error', 'UNAUTHORIZED_ROLE'
        );
    END IF;

    -- 2. Resolve Manager Approval
    IF lower(v_auth.role) IN ('super_admin', 'admin', 'manager', 'staff_admin', 'staffadmin') THEN
        v_approver_id := v_auth.user_id;
    ELSE
        -- Require manager approval token for pos_staff / cashier
        IF p_approval_token IS NOT NULL AND trim(p_approval_token) <> '' THEN
            SELECT * INTO v_approval_auth
            FROM public.validate_active_session_internal(p_approval_token, NULL);

            IF v_approval_auth.is_valid IS TRUE AND lower(COALESCE(v_approval_auth.role, '')) IN ('super_admin', 'admin', 'manager', 'staff_admin', 'staffadmin') THEN
                v_approver_id := v_approval_auth.user_id;
            ELSE
                RETURN jsonb_build_object(
                    'success', false,
                    'code', 'FORBIDDEN',
                    'error', 'INVALID_APPROVAL_TOKEN'
                );
            END IF;
        ELSE
            RETURN jsonb_build_object(
                'success', false,
                'code', 'FORBIDDEN',
                'error', 'MANAGER_APPROVAL_REQUIRED'
            );
        END IF;
    END IF;

    -- 3. Input Validation
    IF p_pos_order_id IS NULL OR p_pos_order_id <= 0 THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_INPUT',
            'error', 'INVALID_POS_ORDER_ID'
        );
    END IF;

    v_refund_key := trim(COALESCE(p_refund_key, ''));
    IF v_refund_key = '' OR length(v_refund_key) > 255 THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_INPUT',
            'error', 'INVALID_REFUND_KEY'
        );
    END IF;

    v_norm_method := UPPER(trim(COALESCE(p_refund_method, '')));
    IF v_norm_method NOT IN ('CASH', 'UPI_MANUAL', 'CARD_MANUAL') THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_REFUND_METHOD',
            'error', 'INVALID_REFUND_METHOD'
        );
    END IF;

    v_reason := trim(COALESCE(p_reason, ''));
    IF length(v_reason) < 3 OR length(v_reason) > 500 THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_INPUT',
            'error', 'INVALID_REFUND_REASON'
        );
    END IF;

    -- 4. Lock Target Master POS Order FOR UPDATE (Prevent concurrent settlement / refund races)
    SELECT * INTO v_pos_order
    FROM public.pos_orders
    WHERE id = p_pos_order_id FOR UPDATE;

    IF v_pos_order.id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'ORDER_NOT_FOUND',
            'error', 'ORDER_NOT_FOUND'
        );
    END IF;

    -- 5. Idempotency Boundary: Same-Key Retry (Read-Only Replay) vs Key Collision
    SELECT * INTO v_existing_key_refund
    FROM public.pay_refunds
    WHERE refund_key = v_refund_key
    LIMIT 1;

    IF v_existing_key_refund.id IS NOT NULL THEN
        IF v_existing_key_refund.pos_order_id = p_pos_order_id THEN
            -- Idempotent Replay (Read-Only Success - 0 Duplicate Inserts)
            RETURN jsonb_build_object(
                'success', true,
                'idempotent_replay', true,
                'code', 'IDEMPOTENT_REPLAY',
                'refund_id', v_existing_key_refund.id,
                'refund_key', v_existing_key_refund.refund_key,
                'pos_order_id', p_pos_order_id,
                'amount', v_existing_key_refund.amount,
                'refund_method', v_existing_key_refund.refund_method,
                'payment_status', 'Refunded'
            );
        ELSE
            RETURN jsonb_build_object(
                'success', false,
                'code', 'REFUND_KEY_COLLISION',
                'error', 'REFUND_KEY_COLLISION'
            );
        END IF;
    END IF;

    -- 6. Check Active/Completed Full Refund for this POS Order
    SELECT * INTO v_existing_active_refund
    FROM public.pay_refunds
    WHERE pos_order_id = p_pos_order_id
      AND UPPER(status) IN ('REQUESTED', 'GATEWAY_PENDING', 'COMPLETED', 'MANUAL_REVIEW_REQUIRED', 'PENDING', 'APPROVED', 'REFUNDED')
    LIMIT 1;

    IF v_existing_active_refund.id IS NOT NULL OR lower(COALESCE(v_pos_order.payment_status, '')) = 'refunded' THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'ALREADY_REFUNDED',
            'error', 'ORDER_ALREADY_REFUNDED'
        );
    END IF;

    -- 7. Normalize Original Order State & Financial Eligibility Checks
    v_orig_pay_status := UPPER(trim(COALESCE(v_pos_order.payment_status, '')));
    v_orig_pay_method := UPPER(trim(COALESCE(v_pos_order.payment_method, '')));
    v_orig_order_status := UPPER(trim(COALESCE(v_pos_order.status, '')));

    -- Reject unpaid order
    IF v_orig_pay_status NOT IN ('PAID', 'SETTLED') AND v_orig_order_status NOT IN ('CLOSED', 'SETTLED', 'COMPLETED') THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'NOT_PAID',
            'error', 'ORDER_NOT_PAID'
        );
    END IF;

    -- Fail-closed for Split payment
    IF v_orig_pay_method = 'SPLIT' THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'SPLIT_REFUND_REQUIRES_ALLOCATION',
            'error', 'SPLIT_REFUND_REQUIRES_ALLOCATION'
        );
    END IF;

    -- Fail-closed for Marketplace payments (Zomato / Swiggy)
    IF v_orig_pay_method IN ('ZOMATO', 'SWIGGY') THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'EXTERNAL_MARKETPLACE_SETTLEMENT',
            'error', 'EXTERNAL_MARKETPLACE_SETTLEMENT'
        );
    END IF;

    -- Fail-closed for Online Gateway payments
    IF v_orig_pay_method IN ('ONLINE', 'RAZORPAY') OR v_pos_order.razorpay_payment_id IS NOT NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'ONLINE_REFUND_REQUIRED',
            'error', 'ONLINE_REFUND_REQUIRED'
        );
    END IF;

    -- Method Compatibility Validation
    IF v_norm_method = 'CASH' AND v_orig_pay_method NOT IN ('CASH', 'PAY AT COUNTER', 'COUNTER', 'PENDING') THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'REFUND_METHOD_MISMATCH',
            'error', 'REFUND_METHOD_MISMATCH'
        );
    ELSIF v_norm_method = 'UPI_MANUAL' AND v_orig_pay_method NOT IN ('UPI', 'UPI_MANUAL') THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'REFUND_METHOD_MISMATCH',
            'error', 'REFUND_METHOD_MISMATCH'
        );
    ELSIF v_norm_method = 'CARD_MANUAL' AND v_orig_pay_method NOT IN ('CARD', 'CARD_MANUAL') THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'REFUND_METHOD_MISMATCH',
            'error', 'REFUND_METHOD_MISMATCH'
        );
    END IF;

    -- 8. Derive Full Authoritative Refund Amount from POS Order Total
    v_refund_amount := COALESCE(v_pos_order.total, 0.00);
    IF v_refund_amount <= 0 THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_INPUT',
            'error', 'INVALID_REFUND_AMOUNT'
        );
    END IF;

    -- 9. Insert Structured Append-Only Refund Ledger Record
    INSERT INTO public.pay_refunds (
        pos_order_id,
        refund_key,
        amount,
        reason,
        status,
        refund_method,
        created_by,
        approved_by
    ) VALUES (
        p_pos_order_id,
        v_refund_key,
        v_refund_amount,
        v_reason,
        'COMPLETED',
        v_norm_method,
        v_auth.user_id,
        v_approver_id
    ) RETURNING id INTO v_refund_id;

    -- 10. Update POS Order Payment Status (Commercial status PRESERVED)
    UPDATE public.pos_orders
    SET payment_status = 'Refunded'
    WHERE id = p_pos_order_id;

    -- 11. Write System Audit Event
    SELECT full_name INTO v_user FROM public.users WHERE id = v_auth.user_id LIMIT 1;
    INSERT INTO public.system_audit_logs (
        user_name,
        user_role,
        action,
        details
    ) VALUES (
        COALESCE(v_user.full_name, 'POS Operator'),
        v_auth.role,
        'record_manual_pos_refund',
        jsonb_build_object(
            'pos_order_id', p_pos_order_id,
            'refund_id', v_refund_id,
            'refund_key', v_refund_key,
            'refund_method', v_norm_method,
            'amount', v_refund_amount,
            'reason', v_reason,
            'created_by', v_auth.user_id,
            'approved_by', v_approver_id
        )
    );

    -- 12. Return Success Envelope
    RETURN jsonb_build_object(
        'success', true,
        'code', 'SUCCESS',
        'refund_id', v_refund_id,
        'refund_key', v_refund_key,
        'pos_order_id', p_pos_order_id,
        'amount', v_refund_amount,
        'refund_method', v_norm_method,
        'payment_status', 'Refunded'
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp;

CREATE OR REPLACE FUNCTION public.secure_initiate_online_refund(
    p_session_token TEXT,
    p_order_id BIGINT,
    p_refund_key TEXT,
    p_reason TEXT
)
RETURNS JSONB AS $$
DECLARE
    v_auth RECORD;
    v_refund_key TEXT;
    v_reason TEXT;
    v_order RECORD;
    v_existing_key_refund RECORD;
    v_existing_active_refund RECORD;
    v_orig_pay_status TEXT;
    v_orig_pay_method TEXT;
    v_total_rupees NUMERIC(10,2);
    v_amount_paise BIGINT;
    v_refund_id BIGINT;
BEGIN
    -- 1. Validate Session Token via Phase 3A Session Helper
    SELECT * INTO v_auth
    FROM public.validate_active_session_internal(p_session_token, NULL);

    IF v_auth.is_valid IS NOT TRUE THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'UNAUTHORIZED',
            'error', COALESCE(v_auth.error_code, 'INVALID_SESSION')
        );
    END IF;

    -- Enforce Role Authorization (Super Admin, Admin, Manager, Staff Admin)
    IF v_auth.role IS NULL OR lower(v_auth.role) IN ('customer', 'user', 'guest') OR lower(v_auth.role) NOT IN ('super_admin', 'admin', 'manager', 'staff_admin', 'staffadmin') THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'UNAUTHORIZED',
            'error', 'UNAUTHORIZED_ROLE'
        );
    END IF;

    -- 2. Input Validation
    IF p_order_id IS NULL OR p_order_id <= 0 THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_INPUT',
            'error', 'INVALID_ORDER_ID'
        );
    END IF;

    v_refund_key := trim(COALESCE(p_refund_key, ''));
    IF v_refund_key = '' OR length(v_refund_key) > 255 THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_INPUT',
            'error', 'INVALID_REFUND_KEY'
        );
    END IF;

    v_reason := trim(COALESCE(p_reason, ''));
    IF length(v_reason) < 3 OR length(v_reason) > 500 THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_INPUT',
            'error', 'INVALID_REFUND_REASON'
        );
    END IF;

    -- 3. Lock Target Master Order FOR UPDATE
    SELECT * INTO v_order
    FROM public.orders
    WHERE id = p_order_id FOR UPDATE;

    IF v_order.id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'ORDER_NOT_FOUND',
            'error', 'ORDER_NOT_FOUND'
        );
    END IF;

    -- 4. Idempotency Boundary: Same-Key Retry Replay
    SELECT * INTO v_existing_key_refund
    FROM public.pay_refunds
    WHERE refund_key = v_refund_key
    LIMIT 1;

    IF v_existing_key_refund.id IS NOT NULL THEN
        IF v_existing_key_refund.order_id = p_order_id THEN
            v_amount_paise := round(COALESCE(v_existing_key_refund.amount, 0) * 100)::BIGINT;
            RETURN jsonb_build_object(
                'success', true,
                'idempotent_replay', true,
                'code', 'IDEMPOTENT_REPLAY',
                'refund_id', v_existing_key_refund.id,
                'refund_key', v_existing_key_refund.refund_key,
                'order_id', p_order_id,
                'razorpay_payment_id', v_order.razorpay_payment_id,
                'amount_rupees', v_existing_key_refund.amount,
                'amount_paise', v_amount_paise,
                'status', v_existing_key_refund.status
            );
        ELSE
            RETURN jsonb_build_object(
                'success', false,
                'code', 'REFUND_KEY_COLLISION',
                'error', 'REFUND_KEY_COLLISION'
            );
        END IF;
    END IF;

    -- 5. Active Refund Check (Different Key)
    SELECT * INTO v_existing_active_refund
    FROM public.pay_refunds
    WHERE order_id = p_order_id
      AND UPPER(status) IN ('REQUESTED', 'GATEWAY_PENDING', 'COMPLETED', 'MANUAL_REVIEW_REQUIRED', 'PENDING', 'APPROVED', 'REFUNDED')
    LIMIT 1;

    IF v_existing_active_refund.id IS NOT NULL OR UPPER(trim(COALESCE(v_order.payment_status, ''))) = 'REFUNDED' THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'ALREADY_REFUNDED',
            'error', 'ORDER_ALREADY_REFUNDED'
        );
    END IF;

    -- 6. Payment Finality & Method Validation
    v_orig_pay_status := UPPER(trim(COALESCE(v_order.payment_status, '')));
    v_orig_pay_method := UPPER(trim(COALESCE(v_order.payment_method, '')));

    -- Reject unpaid order
    IF v_orig_pay_status NOT IN ('PAID', 'CAPTURED') THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'NOT_PAID',
            'error', 'ORDER_NOT_PAID'
        );
    END IF;

    -- Reject non-gateway methods
    IF v_orig_pay_method NOT IN ('ONLINE', 'RAZORPAY') OR v_order.razorpay_payment_id IS NULL OR trim(v_order.razorpay_payment_id) = '' THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'ONLINE_REFUND_NOT_APPLICABLE',
            'error', 'MISSING_RAZORPAY_PAYMENT_ID'
        );
    END IF;

    -- 7. Server Amount Derivation & Paise Conversion
    v_total_rupees := COALESCE(v_order.total, 0.00);
    IF v_total_rupees <= 0 THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_INPUT',
            'error', 'INVALID_REFUND_AMOUNT'
        );
    END IF;

    v_amount_paise := round(v_total_rupees * 100)::BIGINT;

    -- 8. Insert REQUESTED Refund Intent Ledger Record
    INSERT INTO public.pay_refunds (
        order_id,
        refund_key,
        amount,
        reason,
        status,
        refund_method,
        created_by
    ) VALUES (
        p_order_id,
        v_refund_key,
        v_total_rupees,
        v_reason,
        'REQUESTED',
        'GATEWAY',
        v_auth.user_id
    ) RETURNING id INTO v_refund_id;

    -- Return Initiation Details
    RETURN jsonb_build_object(
        'success', true,
        'code', 'SUCCESS',
        'refund_id', v_refund_id,
        'refund_key', v_refund_key,
        'order_id', p_order_id,
        'razorpay_payment_id', v_order.razorpay_payment_id,
        'amount_rupees', v_total_rupees,
        'amount_paise', v_amount_paise,
        'status', 'REQUESTED'
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp;

CREATE OR REPLACE FUNCTION public.secure_confirm_online_refund(
    p_service_key TEXT,
    p_order_id BIGINT,
    p_refund_key TEXT,
    p_gateway_refund_id TEXT,
    p_provider_status TEXT,
    p_error_message TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_refund_key TEXT;
    v_provider_status TEXT;
    v_refund RECORD;
    v_order RECORD;
BEGIN
    -- 1. Service Key / Trusted Server Boundary Check
    IF p_service_key IS NULL OR p_service_key <> 'TRUSTED_EDGE_SERVICE_KEY_2026_ASVK' THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'UNAUTHORIZED',
            'error', 'INVALID_SERVICE_KEY'
        );
    END IF;

    -- 2. Input Validation
    v_refund_key := trim(COALESCE(p_refund_key, ''));
    v_provider_status := UPPER(trim(COALESCE(p_provider_status, '')));

    IF p_order_id IS NULL OR p_order_id <= 0 OR v_refund_key = '' THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_INPUT',
            'error', 'INVALID_CONFIRM_PARAMS'
        );
    END IF;

    -- 3. Lock Target Order and Refund Record FOR UPDATE
    SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
    IF v_order.id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'ORDER_NOT_FOUND',
            'error', 'ORDER_NOT_FOUND'
        );
    END IF;

    SELECT * INTO v_refund FROM public.pay_refunds WHERE refund_key = v_refund_key FOR UPDATE;
    IF v_refund.id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'REFUND_NOT_FOUND',
            'error', 'REFUND_INTENT_NOT_FOUND'
        );
    END IF;

    -- 4. Replay Check (If already COMPLETED)
    IF UPPER(COALESCE(v_refund.status, '')) = 'COMPLETED' THEN
        RETURN jsonb_build_object(
            'success', true,
            'idempotent_replay', true,
            'code', 'IDEMPOTENT_REPLAY',
            'refund_id', v_refund.id,
            'refund_key', v_refund.refund_key,
            'gateway_refund_id', v_refund.gateway_refund_id,
            'status', 'COMPLETED',
            'payment_status', 'REFUNDED'
        );
    END IF;

    -- 5. Handle Provider States
    IF v_provider_status IN ('PROCESSED', 'COMPLETED') THEN
        UPDATE public.pay_refunds
        SET status = 'COMPLETED',
            gateway_refund_id = COALESCE(p_gateway_refund_id, gateway_refund_id),
            updated_at = NOW()
        WHERE id = v_refund.id;

        -- Update order payment status (Commercial orders.status & order_status PRESERVED!)
        UPDATE public.orders
        SET payment_status = 'REFUNDED'
        WHERE id = p_order_id;

        -- System audit log
        INSERT INTO public.system_audit_logs (user_name, user_role, action, details)
        VALUES (
            'Edge Service',
            'service_role',
            'confirm_online_refund_completed',
            jsonb_build_object(
                'order_id', p_order_id,
                'refund_id', v_refund.id,
                'refund_key', v_refund_key,
                'gateway_refund_id', p_gateway_refund_id,
                'amount', v_refund.amount
            )
        );

        RETURN jsonb_build_object(
            'success', true,
            'code', 'SUCCESS',
            'refund_id', v_refund.id,
            'refund_key', v_refund_key,
            'gateway_refund_id', p_gateway_refund_id,
            'status', 'COMPLETED',
            'payment_status', 'REFUNDED'
        );

    ELSIF v_provider_status IN ('PENDING', 'GATEWAY_PENDING') THEN
        UPDATE public.pay_refunds
        SET status = 'GATEWAY_PENDING',
            gateway_refund_id = COALESCE(p_gateway_refund_id, gateway_refund_id),
            updated_at = NOW()
        WHERE id = v_refund.id;

        RETURN jsonb_build_object(
            'success', true,
            'code', 'GATEWAY_PENDING',
            'refund_id', v_refund.id,
            'refund_key', v_refund_key,
            'gateway_refund_id', p_gateway_refund_id,
            'status', 'GATEWAY_PENDING',
            'payment_status', v_order.payment_status
        );

    ELSIF v_provider_status IN ('FAILED', 'REJECTED') THEN
        UPDATE public.pay_refunds
        SET status = 'FAILED',
            reason = COALESCE(v_refund.reason, '') || ' [FAILED: ' || COALESCE(p_error_message, 'Provider error') || ']',
            updated_at = NOW()
        WHERE id = v_refund.id;

        RETURN jsonb_build_object(
            'success', false,
            'code', 'GATEWAY_FAILED',
            'error', COALESCE(p_error_message, 'Razorpay refund failed'),
            'refund_id', v_refund.id,
            'refund_key', v_refund_key,
            'status', 'FAILED',
            'payment_status', v_order.payment_status
        );

    ELSE
        -- Manual review fallback
        UPDATE public.pay_refunds
        SET status = 'MANUAL_REVIEW_REQUIRED',
            updated_at = NOW()
        WHERE id = v_refund.id;

        RETURN jsonb_build_object(
            'success', false,
            'code', 'MANUAL_REVIEW_REQUIRED',
            'error', 'Unknown provider refund state',
            'refund_id', v_refund.id,
            'refund_key', v_refund_key,
            'status', 'MANUAL_REVIEW_REQUIRED'
        );
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp;

CREATE OR REPLACE FUNCTION public._build_qr_order_accepted_response(
    p_order_id BIGINT,
    p_idempotent_replay BOOLEAN DEFAULT FALSE,
    p_already_accepted BOOLEAN DEFAULT FALSE
)
RETURNS JSONB AS $$
DECLARE
    v_order RECORD;
    v_items JSONB;
BEGIN
    SELECT * INTO v_order FROM public.pos_orders WHERE id = p_order_id;
    IF v_order IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
    END IF;

    SELECT jsonb_agg(
        jsonb_build_object(
            'id', id,
            'order_id', order_id,
            'product_id', product_id,
            'product_name', product_name,
            'quantity', quantity,
            'price', price,
            'total', total,
            'status', status,
            'rejection_reason', rejection_reason,
            'notes', COALESCE(rejection_reason, modified_reason, ''),
            'variant_name', variant_name,
            'addons', addons,
            'session_item_id', session_item_id
        )
    ) INTO v_items
    FROM public.pos_order_items
    WHERE order_id = p_order_id;

    RETURN jsonb_build_object(
        'success', true,
        'order_id', v_order.id,
        'table_id', v_order.table_id,
        'table_session_id', v_order.table_session_id,
        'status', v_order.status,
        'subtotal', v_order.subtotal,
        'gst', v_order.gst,
        'total', v_order.total,
        'accept_key', v_order.accept_key,
        'idempotent_replay', p_idempotent_replay,
        'already_accepted', p_already_accepted,
        'items', COALESCE(v_items, '[]'::jsonb)
    );
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions, pg_temp;

CREATE OR REPLACE FUNCTION public.secure_accept_qr_order(
    p_session_token TEXT,
    p_order_id BIGINT,
    p_accept_key TEXT,
    p_item_decisions JSONB DEFAULT '[]'::jsonb
)
RETURNS JSONB AS $$
DECLARE
    v_auth RECORD;
    v_order RECORD;
    v_table RECORD;
    v_table_session RECORD;
    v_active_sess_status TEXT;
    v_existing_order RECORD;
    
    v_dec_elem JSONB;
    v_dec_item_id BIGINT;
    v_dec_qty INT;
    v_dec_reason TEXT;
    
    v_item RECORD;
    v_accepted_qty INT;
    v_reason TEXT;
    v_item_total NUMERIC;
    v_accepted_item_count INT := 0;
    
    v_new_subtotal NUMERIC := 0;
    v_new_gst NUMERIC := 0;
    v_new_total NUMERIC := 0;
    
    v_seen_item_ids BIGINT[] := ARRAY[]::BIGINT[];
    v_target_item_ids BIGINT[] := ARRAY[]::BIGINT[];
    v_quantities_changed BOOLEAN := FALSE;
BEGIN
    -- 1. Input Validations
    IF p_session_token IS NULL OR TRIM(p_session_token) = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_TOKEN', 'message', 'Session token is required.');
    END IF;

    IF p_order_id IS NULL OR p_order_id <= 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_ORDER_ID', 'message', 'Valid numeric order ID is required.');
    END IF;

    IF p_accept_key IS NULL OR TRIM(p_accept_key) = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_ACCEPT_KEY', 'message', 'Accept key is required.');
    END IF;

    -- 2. Validate Operator Auth Session & Role
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF v_auth.is_valid IS NOT TRUE THEN
        RETURN jsonb_build_object('success', false, 'error', COALESCE(v_auth.error_code, 'INVALID_SESSION'));
    END IF;

    IF v_auth.role IS NULL OR lower(v_auth.role) IN ('customer', 'user', 'guest') 
       OR lower(v_auth.role) NOT IN ('pos', 'pos_staff', 'cashier', 'staff', 'manager', 'admin', 'super_admin', 'staffadmin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'UNAUTHORIZED_ROLE', 'message', 'Role unauthorized for QR order acceptance.');
    END IF;

    -- 3. Idempotency Check by accept_key across pos_orders
    SELECT * INTO v_existing_order
    FROM public.pos_orders
    WHERE accept_key = p_accept_key
    LIMIT 1;

    IF FOUND THEN
        IF v_existing_order.id != p_order_id THEN
            RETURN jsonb_build_object('success', false, 'error', 'KEY_COLLISION', 'message', 'Accept key already used for a different order.');
        ELSE
            RETURN public._build_qr_order_accepted_response(v_existing_order.id, TRUE, FALSE);
        END IF;
    END IF;

    -- 4. Lock Target Order
    SELECT * INTO v_order
    FROM public.pos_orders
    WHERE id = p_order_id
    FOR UPDATE;

    IF v_order IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND', 'message', 'Target QR order not found.');
    END IF;

    -- Check if already processed
    IF v_order.accept_key IS NOT NULL AND v_order.accept_key = p_accept_key THEN
        RETURN public._build_qr_order_accepted_response(v_order.id, TRUE, FALSE);
    END IF;

    IF v_order.status != 'waiting_confirmation' THEN
        IF v_order.status IN ('OPEN', 'Confirmed', 'Preparing', 'Ready', 'Completed') THEN
            RETURN public._build_qr_order_accepted_response(v_order.id, FALSE, TRUE);
        ELSE
            RETURN jsonb_build_object('success', false, 'error', 'ORDER_TERMINAL', 'status', v_order.status, 'message', 'Order is in terminal state.');
        END IF;
    END IF;

    -- 5. Session & Table Ownership Verification
    IF v_order.table_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'MISSING_TABLE_ID', 'message', 'Order is not linked to a table.');
    END IF;

    SELECT * INTO v_table
    FROM public.pos_tables
    WHERE id = v_order.table_id
    FOR UPDATE;

    IF v_table IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'TABLE_NOT_FOUND', 'message', 'Target table not found.');
    END IF;

    IF v_order.table_session_id IS NOT NULL THEN
        SELECT * INTO v_table_session
        FROM public.table_sessions
        WHERE id = v_order.table_session_id;

        IF v_table_session IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error', 'SESSION_NOT_FOUND', 'message', 'Linked table session not found.');
        END IF;

        IF v_table_session.status = 'closed' THEN
            RETURN jsonb_build_object('success', false, 'error', 'STALE_SESSION', 'message', 'Linked table session is closed.');
        END IF;

        IF v_table_session.table_id != v_order.table_id THEN
            RETURN jsonb_build_object('success', false, 'error', 'WRONG_TABLE_SESSION', 'message', 'Table session belongs to a different table.');
        END IF;
    END IF;

    -- Check table active session conflict
    IF v_table.active_session_id IS NOT NULL AND v_order.table_session_id IS NOT NULL AND v_table.active_session_id != v_order.table_session_id THEN
        SELECT status INTO v_active_sess_status
        FROM public.table_sessions
        WHERE id = v_table.active_session_id;

        IF v_active_sess_status = 'active' THEN
            RETURN jsonb_build_object('success', false, 'error', 'TABLE_BUSY_OTHER_SESSION', 'message', 'Table is currently occupied by another active session.');
        END IF;
    END IF;

    -- 6. Lock and Collect Target Order Items
    SELECT ARRAY_AGG(id) INTO v_target_item_ids
    FROM public.pos_order_items
    WHERE order_id = p_order_id;

    IF v_target_item_ids IS NULL OR ARRAY_LENGTH(v_target_item_ids, 1) = 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'NO_ORDER_ITEMS', 'message', 'QR order has no order items.');
    END IF;

    PERFORM 1 FROM public.pos_order_items WHERE order_id = p_order_id FOR UPDATE;

    -- 7. Process Item Decision Overrides & In-Memory Validation (Validate foreign items, duplicates, negative/excessive qty)
    IF p_item_decisions IS NOT NULL AND jsonb_typeof(p_item_decisions) = 'array' AND jsonb_array_length(p_item_decisions) > 0 THEN
        FOR v_dec_elem IN SELECT * FROM jsonb_array_elements(p_item_decisions)
        LOOP
            v_dec_item_id := COALESCE((v_dec_elem->>'item_id')::BIGINT, (v_dec_elem->>'id')::BIGINT);
            v_dec_qty := (v_dec_elem->>'quantity')::INT;
            v_dec_reason := TRIM(COALESCE(v_dec_elem->>'reason', ''));

            IF v_dec_item_id IS NULL THEN
                RETURN jsonb_build_object('success', false, 'error', 'INVALID_ITEM_ID', 'message', 'Item decision missing item_id.');
            END IF;

            -- Check for duplicate decision for same item
            IF v_dec_item_id = ANY(v_seen_item_ids) THEN
                RETURN jsonb_build_object('success', false, 'error', 'DUPLICATE_ITEM_DECISION', 'message', 'Duplicate decision for item ID ' || v_dec_item_id);
            END IF;
            v_seen_item_ids := ARRAY_APPEND(v_seen_item_ids, v_dec_item_id);

            -- Check if item belongs to target order
            IF NOT (v_dec_item_id = ANY(v_target_item_ids)) THEN
                RETURN jsonb_build_object('success', false, 'error', 'FOREIGN_ITEM_ID', 'message', 'Item ID ' || v_dec_item_id || ' does not belong to target order.');
            END IF;

            IF v_dec_qty IS NULL OR v_dec_qty < 0 THEN
                RETURN jsonb_build_object('success', false, 'error', 'INVALID_QUANTITY', 'message', 'Item quantity cannot be negative.');
            END IF;

            -- Check quantity against original requested
            SELECT * INTO v_item FROM public.pos_order_items WHERE id = v_dec_item_id;
            IF v_dec_qty > v_item.quantity THEN
                RETURN jsonb_build_object('success', false, 'error', 'QUANTITY_EXCEEDS_ORIGINAL', 'message', 'Accepted quantity cannot exceed original requested quantity.');
            END IF;
        END LOOP;
    END IF;

    -- 8. Compute resulting accepted items count & new subtotal IN MEMORY BEFORE any UPDATEs
    v_accepted_item_count := 0;
    v_new_subtotal := 0;
    v_quantities_changed := FALSE;

    FOR v_item IN SELECT * FROM public.pos_order_items WHERE order_id = p_order_id LOOP
        v_dec_qty := NULL;

        IF p_item_decisions IS NOT NULL AND jsonb_typeof(p_item_decisions) = 'array' THEN
            SELECT (elem->>'quantity')::INT
            INTO v_dec_qty
            FROM jsonb_array_elements(p_item_decisions) AS elem
            WHERE COALESCE((elem->>'item_id')::BIGINT, (elem->>'id')::BIGINT) = v_item.id
            LIMIT 1;
        END IF;

        IF v_dec_qty IS NOT NULL THEN
            v_accepted_qty := v_dec_qty;
        ELSE
            v_accepted_qty := v_item.quantity;
        END IF;

        IF v_accepted_qty > 0 THEN
            v_accepted_item_count := v_accepted_item_count + 1;
            v_new_subtotal := v_new_subtotal + (v_item.price * v_accepted_qty);
        END IF;

        IF v_accepted_qty != v_item.quantity THEN
            v_quantities_changed := TRUE;
        END IF;
    END LOOP;

    -- 9. Zero Accepted Item Gate (Section 6) - IN MEMORY FAIL CLOSED BEFORE ANY UPDATES
    IF v_accepted_item_count = 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'ALL_ITEMS_REJECTED', 'message', 'Cannot accept order with zero accepted items. Use Reject Order instead.');
    END IF;

    -- 10. Recalculate Order Totals if items changed
    IF v_quantities_changed THEN
        IF v_order.subtotal > 0 THEN
            v_new_gst := ROUND((v_new_subtotal * COALESCE(v_order.gst, 0) / v_order.subtotal), 2);
        ELSE
            v_new_gst := ROUND(v_new_subtotal * 0.05, 2);
        END IF;

        v_new_total := v_new_subtotal + v_new_gst 
                       + COALESCE(v_order.delivery_fee, 0) 
                       - COALESCE(v_order.coupon_discount, 0) 
                       - COALESCE(v_order.manual_discount_amount, 0) 
                       - COALESCE(v_order.wallet_discount, 0);
    ELSE
        v_new_subtotal := v_order.subtotal;
        v_new_gst := v_order.gst;
        v_new_total := v_order.total;
    END IF;

    -- 11. All Validations Passed! Now execute Database Updates atomically
    FOR v_item IN SELECT * FROM public.pos_order_items WHERE order_id = p_order_id LOOP
        v_dec_qty := NULL;
        v_dec_reason := NULL;

        IF p_item_decisions IS NOT NULL AND jsonb_typeof(p_item_decisions) = 'array' THEN
            SELECT (elem->>'quantity')::INT, TRIM(COALESCE(elem->>'reason', ''))
            INTO v_dec_qty, v_dec_reason
            FROM jsonb_array_elements(p_item_decisions) AS elem
            WHERE COALESCE((elem->>'item_id')::BIGINT, (elem->>'id')::BIGINT) = v_item.id
            LIMIT 1;
        END IF;

        IF v_dec_qty IS NOT NULL THEN
            v_accepted_qty := v_dec_qty;
            v_reason := v_dec_reason;
        ELSE
            v_accepted_qty := v_item.quantity;
            v_reason := NULL;
        END IF;

        IF v_accepted_qty = 0 THEN
            UPDATE public.pos_order_items
            SET status = 'Rejected',
                rejection_reason = COALESCE(NULLIF(v_reason, ''), 'Rejected by cashier at accept')
            WHERE id = v_item.id;
        ELSE
            v_item_total := v_item.price * v_accepted_qty;
            UPDATE public.pos_order_items
            SET status = 'Accepted',
                quantity = v_accepted_qty,
                total = v_item_total,
                rejection_reason = CASE WHEN v_reason IS NOT NULL AND v_reason <> '' AND v_accepted_qty <> v_item.quantity
                                        THEN 'Qty adjusted by cashier: ' || v_item.quantity || ' -> ' || v_accepted_qty || '. Reason: ' || v_reason
                                        ELSE rejection_reason END
            WHERE id = v_item.id;
        END IF;
    END LOOP;

    -- 11b. [QR ITEM IDENTITY] Backfill the deterministic POS line identity
    -- on this order's rows if they were submitted before
    -- 20260929180000 (NULL session_item_id). Same formula as
    -- deriveStableQrLineUuid(id); rows that already have one are untouched.
    -- Scoped to THIS order being accepted -- not a historical cleanup.
    UPDATE public.pos_order_items
    SET session_item_id = substr(lpad(to_hex(id), 32, '0'), 1, 8) || '-' || substr(lpad(to_hex(id), 32, '0'), 9, 4) || '-5' || substr(lpad(to_hex(id), 32, '0'), 14, 3) || '-a' || substr(lpad(to_hex(id), 32, '0'), 18, 3) || '-' || substr(lpad(to_hex(id), 32, '0'), 21, 12)
    WHERE order_id = p_order_id
      AND session_item_id IS NULL;

    -- 12. Update pos_orders state to the canonical POS dine-in status OPEN
    -- (was 'Confirmed'; Confirmed/Preparing are outside the POS lifecycle
    -- that secure_cancel_pos_order accepts).
    UPDATE public.pos_orders
    SET status = 'OPEN',
        order_source = COALESCE(order_source, 'pos_dinein'),
        subtotal = v_new_subtotal,
        gst = v_new_gst,
        total = v_new_total,
        accept_key = p_accept_key,
        updated_at = NOW(),
        updated_by = COALESCE(v_auth.role, 'pos')
    WHERE id = p_order_id;

    -- 13. Update pos_table_notifications
    UPDATE public.pos_table_notifications
    SET status = 'accepted'
    WHERE table_id = v_order.table_id
      AND type IN ('new_order', 'new_qr_order')
      AND status IN ('pending', 'displayed');

    -- 14. Update pos_tables pointers safely (Section 8)
    IF v_table.status != 'occupied' OR v_table.active_session_id IS NULL THEN
        UPDATE public.pos_tables
        SET status = 'occupied',
            active_session_id = COALESCE(v_order.table_session_id, active_session_id),
            active_order_id = v_order.id::text,
            guests = COALESCE(guests, 4),
            updated_at = NOW()
        WHERE id = v_order.table_id;
    ELSIF v_table.active_session_id = v_order.table_session_id AND (v_table.active_order_id IS NULL OR v_table.active_order_id = '') THEN
        UPDATE public.pos_tables
        SET active_order_id = v_order.id::text,
            updated_at = NOW()
        WHERE id = v_order.table_id;
    END IF;

    -- 15. Write System Audit Log
    INSERT INTO public.system_audit_logs (
        user_name,
        user_role,
        action,
        device,
        details
    ) VALUES (
        'POS Cashier',
        v_auth.role,
        'accept_qr_order',
        'POS Terminal',
        jsonb_build_object(
            'order_id', p_order_id,
            'accept_key', p_accept_key,
            'accepted_items', v_accepted_item_count,
            'subtotal', v_new_subtotal,
            'total', v_new_total,
            'table_id', v_order.table_id,
            'table_session_id', v_order.table_session_id
        )
    );

    RETURN public._build_qr_order_accepted_response(p_order_id, FALSE, FALSE);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp;

CREATE OR REPLACE FUNCTION public.secure_reject_qr_order(
    p_session_token TEXT,
    p_order_id BIGINT,
    p_rejection_key TEXT,
    p_reason TEXT DEFAULT 'Removed by Restaurant'
)
RETURNS JSONB AS $$
DECLARE
    v_auth RECORD;
    v_order RECORD;
    v_existing_order RECORD;
    v_clean_reason TEXT;
BEGIN
    -- 1. Input Validations
    IF p_session_token IS NULL OR TRIM(p_session_token) = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_TOKEN', 'message', 'Session token is required.');
    END IF;

    IF p_order_id IS NULL OR p_order_id <= 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_ORDER_ID', 'message', 'Valid numeric order ID is required.');
    END IF;

    IF p_rejection_key IS NULL OR TRIM(p_rejection_key) = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_REJECTION_KEY', 'message', 'Rejection key is required.');
    END IF;

    v_clean_reason := TRIM(COALESCE(p_reason, ''));
    IF v_clean_reason = '' THEN
        v_clean_reason := 'Removed by Restaurant';
    END IF;
    IF LENGTH(v_clean_reason) > 500 THEN
        v_clean_reason := SUBSTRING(v_clean_reason FROM 1 FOR 500);
    END IF;

    -- 2. Validate Operator Auth Session & Role
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF v_auth.is_valid IS NOT TRUE THEN
        RETURN jsonb_build_object('success', false, 'error', COALESCE(v_auth.error_code, 'INVALID_SESSION'));
    END IF;

    IF v_auth.role IS NULL OR lower(v_auth.role) IN ('customer', 'user', 'guest') 
       OR lower(v_auth.role) NOT IN ('pos', 'pos_staff', 'cashier', 'staff', 'manager', 'admin', 'super_admin', 'staffadmin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'UNAUTHORIZED_ROLE', 'message', 'Role unauthorized for QR order rejection.');
    END IF;

    -- 3. Idempotency Check by rejection_key across pos_orders
    SELECT * INTO v_existing_order
    FROM public.pos_orders
    WHERE rejection_key = p_rejection_key
    LIMIT 1;

    IF FOUND THEN
        IF v_existing_order.id != p_order_id THEN
            RETURN jsonb_build_object('success', false, 'error', 'KEY_COLLISION', 'message', 'Rejection key already used for a different order.');
        ELSE
            RETURN jsonb_build_object(
                'success', true,
                'idempotent_replay', true,
                'order_id', p_order_id,
                'status', 'Rejected',
                'reason', v_existing_order.rejection_reason
            );
        END IF;
    END IF;

    -- 4. Lock Target Order
    SELECT * INTO v_order
    FROM public.pos_orders
    WHERE id = p_order_id
    FOR UPDATE;

    IF v_order IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND', 'message', 'Target QR order not found.');
    END IF;

    IF v_order.rejection_key IS NOT NULL AND v_order.rejection_key = p_rejection_key THEN
        RETURN jsonb_build_object(
            'success', true,
            'idempotent_replay', true,
            'order_id', p_order_id,
            'status', 'Rejected',
            'reason', v_order.rejection_reason
        );
    END IF;

    IF v_order.status = 'Rejected' THEN
        RETURN jsonb_build_object(
            'success', true,
            'already_rejected', true,
            'order_id', p_order_id,
            'status', 'Rejected',
            'reason', v_order.rejection_reason
        );
    END IF;

    IF v_order.status IN ('Confirmed', 'Preparing', 'Ready', 'Completed') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'ORDER_ALREADY_ACCEPTED',
            'message', 'Order has already been confirmed/accepted and cannot be rejected via QR reject.'
        );
    END IF;

    IF v_order.status != 'waiting_confirmation' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'ORDER_TERMINAL',
            'status', v_order.status,
            'message', 'Order is in a non-waiting state.'
        );
    END IF;

    -- 5. Execute Rejection Updates inside single Postgres Transaction
    UPDATE public.pos_orders
    SET status = 'Rejected',
        cancel_reason = v_clean_reason,
        rejection_reason = v_clean_reason,
        rejection_key = p_rejection_key,
        updated_at = NOW(),
        updated_by = COALESCE(v_auth.role, 'pos')
    WHERE id = p_order_id;

    UPDATE public.pos_order_items
    SET status = 'Rejected',
        rejection_reason = v_clean_reason
    WHERE order_id = p_order_id;

    IF v_order.table_id IS NOT NULL THEN
        UPDATE public.pos_table_notifications
        SET status = 'rejected'
        WHERE table_id = v_order.table_id
          AND type IN ('new_order', 'new_qr_order')
          AND status IN ('pending', 'displayed');
    END IF;

    -- 6. Write System Audit Log
    INSERT INTO public.system_audit_logs (
        user_name,
        user_role,
        action,
        device,
        details
    ) VALUES (
        'POS Cashier',
        v_auth.role,
        'reject_qr_order',
        'POS Terminal',
        jsonb_build_object(
            'order_id', p_order_id,
            'rejection_key', p_rejection_key,
            'reason', v_clean_reason,
            'table_id', v_order.table_id,
            'table_session_id', v_order.table_session_id
        )
    );

    RETURN jsonb_build_object(
        'success', true,
        'order_id', p_order_id,
        'status', 'Rejected',
        'reason', v_clean_reason
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp;

CREATE OR REPLACE FUNCTION public.secure_check_customer_exists(
    p_phone TEXT
)
RETURNS JSONB AS $$
DECLARE
    v_clean_phone TEXT;
    v_exists BOOLEAN := FALSE;
BEGIN
    v_clean_phone := TRIM(COALESCE(p_phone, ''));
    IF v_clean_phone = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_PHONE', 'message', 'Phone number is required.');
    END IF;

    -- Strip leading +91 or spaces if present for normalization
    IF v_clean_phone LIKE '+91%' THEN
        v_clean_phone := substring(v_clean_phone from 4);
    END IF;
    v_clean_phone := REGEXP_REPLACE(v_clean_phone, '\D', '', 'g');

    SELECT EXISTS (
        SELECT 1 FROM public.users 
        WHERE (phone = v_clean_phone OR mobile = v_clean_phone)
    ) INTO v_exists;

    RETURN jsonb_build_object(
        'success', true,
        'exists', v_exists
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION public.secure_customer_login(
    p_phone TEXT,
    p_pin TEXT
)
RETURNS JSONB AS $$
DECLARE
    v_clean_phone TEXT;
    v_clean_pin TEXT;
    v_user RECORD;
    v_customer_token TEXT;
    v_match BOOLEAN := FALSE;
BEGIN
    v_clean_phone := TRIM(COALESCE(p_phone, ''));
    v_clean_pin := TRIM(COALESCE(p_pin, ''));

    IF v_clean_phone = '' OR v_clean_pin = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_INPUT', 'message', 'Phone and 4-digit PIN are required.');
    END IF;

    IF v_clean_phone LIKE '+91%' THEN
        v_clean_phone := substring(v_clean_phone from 4);
    END IF;
    v_clean_phone := REGEXP_REPLACE(v_clean_phone, '\D', '', 'g');

    -- Locate user
    SELECT * INTO v_user
    FROM public.users
    WHERE (phone = v_clean_phone OR mobile = v_clean_phone)
    LIMIT 1;

    IF v_user IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_CREDENTIALS', 'message', 'Invalid phone number or PIN.');
    END IF;

    IF v_user.status IS NOT NULL AND v_user.status IN ('inactive', 'banned', 'disabled') THEN
        RETURN jsonb_build_object('success', false, 'error', 'ACCOUNT_DISABLED', 'message', 'Account is disabled. Please contact support.');
    END IF;

    IF v_user.pin_hash IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_CREDENTIALS', 'message', 'Invalid phone number or PIN.');
    END IF;

    -- Verify PIN server-side using extensions.crypt
    IF replace(v_user.pin_hash, '$2b$', '$2a$') = extensions.crypt(v_clean_pin, replace(v_user.pin_hash, '$2b$', '$2a$')) THEN
        v_match := TRUE;
    END IF;

    IF NOT v_match THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_CREDENTIALS', 'message', 'Invalid phone number or PIN.');
    END IF;

    -- Update timestamp
    UPDATE public.users SET updated_at = NOW() WHERE id = v_user.id;

    -- Issue customer session token directly
    v_customer_token := encode(extensions.gen_random_bytes(32), 'hex');
    INSERT INTO public.active_sessions (
        user_id,
        token,
        device,
        ip_address,
        location,
        created_at,
        expires_at
    ) VALUES (
        v_user.id,
        v_customer_token,
        'Customer Website Browser',
        '127.0.0.1',
        'Online',
        NOW(),
        NOW() + INTERVAL '30 days'
    );

    -- Ensure customer profile exists
    INSERT INTO public.customers (name, mobile, email, source, created_at, updated_at)
    VALUES (COALESCE(v_user.name, v_user.full_name, 'Customer'), v_clean_phone, v_user.email, 'WEBSITE', NOW(), NOW())
    ON CONFLICT (mobile) DO UPDATE SET updated_at = NOW();

    RETURN jsonb_build_object(
        'success', true,
        'token', v_customer_token,
        'user', jsonb_build_object(
            'id', v_user.id,
            'name', COALESCE(v_user.name, v_user.full_name, 'Customer'),
            'full_name', COALESCE(v_user.full_name, v_user.name, 'Customer'),
            'phone', COALESCE(v_user.phone, v_user.mobile, v_clean_phone),
            'mobile', COALESCE(v_user.mobile, v_user.phone, v_clean_phone),
            'email', COALESCE(v_user.email, ''),
            'role', COALESCE(v_user.role, 'customer')
        )
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION public.secure_customer_signup(
    p_name TEXT,
    p_phone TEXT,
    p_pin TEXT
)
RETURNS JSONB AS $$
DECLARE
    v_clean_phone TEXT;
    v_existing_user RECORD;
BEGIN
    v_clean_phone := TRIM(COALESCE(p_phone, ''));
    IF v_clean_phone LIKE '+91%' THEN
        v_clean_phone := substring(v_clean_phone from 4);
    END IF;
    v_clean_phone := REGEXP_REPLACE(v_clean_phone, '\D', '', 'g');

    -- Check if user exists with non-null PIN
    SELECT id, pin_hash INTO v_existing_user
    FROM public.users
    WHERE (phone = v_clean_phone OR mobile = v_clean_phone)
    ORDER BY id ASC
    LIMIT 1;

    IF v_existing_user.id IS NOT NULL AND v_existing_user.pin_hash IS NOT NULL AND LENGTH(TRIM(v_existing_user.pin_hash)) > 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'USER_ALREADY_EXISTS', 'message', 'An account already exists for this phone number.');
    END IF;

    -- Route to secure activation/creation logic
    RETURN public.secure_activate_migrated_customer(p_name, p_phone, p_pin);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION public.secure_list_internal_users(
    p_session_token TEXT
)
RETURNS JSONB AS $$
DECLARE
    v_user_id BIGINT;
    v_role TEXT;
    v_branch_id BIGINT;
    v_is_valid BOOLEAN := FALSE;
    v_error_code TEXT;
    v_users JSONB;
BEGIN
    SELECT user_id, role, branch_id, is_valid, error_code 
    INTO v_user_id, v_role, v_branch_id, v_is_valid, v_error_code 
    FROM public.validate_active_session_internal(p_session_token);

    IF NOT v_is_valid OR v_is_valid IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', COALESCE(v_error_code, 'UNAUTHORIZED'), 'message', 'Invalid or expired staff session.');
    END IF;

    IF v_role NOT IN ('admin', 'manager', 'cashier', 'system_admin', 'super_admin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'FORBIDDEN', 'message', 'Permission denied.');
    END IF;

    SELECT jsonb_agg(
        jsonb_build_object(
            'id', id,
            'name', COALESCE(name, full_name, 'User'),
            'full_name', COALESCE(full_name, name, 'User'),
            'phone', COALESCE(phone, mobile, ''),
            'mobile', COALESCE(mobile, phone, ''),
            'email', COALESCE(email, ''),
            'role', COALESCE(role, 'customer'),
            'status', COALESCE(status, 'active'),
            'employee_code', COALESCE(employee_code, ''),
            'branch_id', branch_id,
            'created_at', created_at
        )
    ) INTO v_users
    FROM public.users;

    RETURN jsonb_build_object(
        'success', true,
        'users', COALESCE(v_users, '[]'::jsonb)
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION public.secure_get_active_sessions_admin(
    p_session_token TEXT
)
RETURNS JSONB AS $$
DECLARE
    v_user_id BIGINT;
    v_role TEXT;
    v_branch_id BIGINT;
    v_is_valid BOOLEAN := FALSE;
    v_error_code TEXT;
    v_sessions JSONB;
BEGIN
    SELECT user_id, role, branch_id, is_valid, error_code 
    INTO v_user_id, v_role, v_branch_id, v_is_valid, v_error_code 
    FROM public.validate_active_session_internal(p_session_token);

    IF NOT v_is_valid OR v_is_valid IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', COALESCE(v_error_code, 'UNAUTHORIZED'), 'message', 'Invalid or expired staff session.');
    END IF;

    IF v_role NOT IN ('admin', 'system_admin', 'super_admin', 'manager') THEN
        RETURN jsonb_build_object('success', false, 'error', 'FORBIDDEN', 'message', 'Permission denied.');
    END IF;

    -- Returns session metadata EXCLUDING the raw bearer tokens of other users!
    SELECT jsonb_agg(
        jsonb_build_object(
            'id', s.id,
            'user_id', s.user_id,
            'user_name', COALESCE(u.name, u.full_name, 'User'),
            'role', COALESCE(u.role, 'staff'),
            'ip_address', COALESCE(s.ip_address, '127.0.0.1'),
            'device', COALESCE(s.device, 'Unknown'),
            'location', COALESCE(s.location, 'Unknown'),
            'created_at', s.created_at,
            'expires_at', s.expires_at
        )
    ) INTO v_sessions
    FROM public.active_sessions s
    LEFT JOIN public.users u ON u.id = s.user_id
    WHERE s.expires_at > NOW();

    RETURN jsonb_build_object(
        'success', true,
        'sessions', COALESCE(v_sessions, '[]'::jsonb)
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION public.secure_get_customer_addresses(p_session_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_addresses JSONB;
BEGIN
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF NOT v_auth.is_valid THEN
        RETURN jsonb_build_object('success', false, 'error', v_auth.error_code);
    END IF;

    SELECT jsonb_agg(
        jsonb_build_object(
            'id', a.id,
            'user_id', a.user_id,
            'full_name', a.full_name,
            'user_phone', a.user_phone,
            'house', a.house,
            'area', a.area,
            'landmark', a.landmark,
            'city', a.city,
            'pincode', a.pincode,
            'latitude', a.latitude,
            'longitude', a.longitude,
            'map_link', a.map_link,
            'address_label', a.address_label,
            'delivery_zone', a.delivery_zone,
            'last_used_at', a.last_used_at,
            'created_at', a.created_at
        ) ORDER BY a.id DESC
    ) INTO v_addresses
    FROM public.addresses a
    WHERE a.user_id = v_auth.user_id;

    RETURN jsonb_build_object(
        'success', true,
        'addresses', COALESCE(v_addresses, '[]'::jsonb)
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_save_customer_address(p_session_token text, p_address jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_address_id BIGINT;
    v_raw_id TEXT;
BEGIN
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF NOT v_auth.is_valid THEN
        RETURN jsonb_build_object('success', false, 'error', v_auth.error_code);
    END IF;

    v_raw_id := TRIM(COALESCE(p_address->>'id', ''));

    IF v_raw_id <> '' AND v_raw_id IS NOT NULL THEN
        v_address_id := v_raw_id::BIGINT;

        -- Update existing address only if owned by authenticated user
        UPDATE public.addresses
        SET full_name = COALESCE(p_address->>'full_name', full_name),
            user_phone = COALESCE(p_address->>'user_phone', user_phone),
            house = COALESCE(p_address->>'house', house),
            area = COALESCE(p_address->>'area', area),
            landmark = COALESCE(p_address->>'landmark', landmark),
            city = COALESCE(p_address->>'city', city),
            pincode = COALESCE(p_address->>'pincode', pincode),
            latitude = CASE WHEN (p_address->>'latitude') IS NOT NULL AND (p_address->>'latitude') <> '' THEN (p_address->>'latitude')::NUMERIC ELSE latitude END,
            longitude = CASE WHEN (p_address->>'longitude') IS NOT NULL AND (p_address->>'longitude') <> '' THEN (p_address->>'longitude')::NUMERIC ELSE longitude END,
            map_link = COALESCE(p_address->>'map_link', map_link),
            address_label = COALESCE(p_address->>'address_label', address_label),
            delivery_zone = COALESCE(p_address->>'delivery_zone', delivery_zone)
        WHERE id = v_address_id AND user_id = v_auth.user_id;

        IF NOT FOUND THEN
            RETURN jsonb_build_object('success', false, 'error', 'ADDRESS_NOT_FOUND_OR_UNAUTHORIZED');
        END IF;
    ELSE
        -- Insert new address bound to authenticated user
        INSERT INTO public.addresses (
            user_id,
            full_name,
            user_phone,
            house,
            area,
            landmark,
            city,
            pincode,
            latitude,
            longitude,
            map_link,
            address_label,
            delivery_zone,
            created_at
        ) VALUES (
            v_auth.user_id,
            p_address->>'full_name',
            p_address->>'user_phone',
            p_address->>'house',
            p_address->>'area',
            p_address->>'landmark',
            p_address->>'city',
            p_address->>'pincode',
            CASE WHEN (p_address->>'latitude') IS NOT NULL AND (p_address->>'latitude') <> '' THEN (p_address->>'latitude')::NUMERIC ELSE NULL END,
            CASE WHEN (p_address->>'longitude') IS NOT NULL AND (p_address->>'longitude') <> '' THEN (p_address->>'longitude')::NUMERIC ELSE NULL END,
            p_address->>'map_link',
            COALESCE(p_address->>'address_label', 'Home'),
            p_address->>'delivery_zone',
            NOW()
        ) RETURNING id INTO v_address_id;
    END IF;

    RETURN jsonb_build_object('success', true, 'address_id', v_address_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_delete_customer_address(p_session_token text, p_address_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
BEGIN
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF NOT v_auth.is_valid THEN
        RETURN jsonb_build_object('success', false, 'error', v_auth.error_code);
    END IF;

    DELETE FROM public.addresses
    WHERE id = p_address_id AND user_id = v_auth.user_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'ADDRESS_NOT_FOUND_OR_UNAUTHORIZED');
    END IF;

    RETURN jsonb_build_object('success', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_get_customer_order_details(p_session_token text, p_order_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_order RECORD;
    v_items JSONB;
    v_user_phone TEXT;
    v_is_staff BOOLEAN := FALSE;
BEGIN
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF NOT v_auth.is_valid THEN
        RETURN jsonb_build_object('success', false, 'error', v_auth.error_code);
    END IF;

    IF v_auth.role IN ('admin', 'manager', 'cashier', 'kitchen', 'staff', 'pos_staff', 'super_admin') THEN
        v_is_staff := TRUE;
    END IF;

    IF NOT v_is_staff THEN
        SELECT COALESCE(mobile, phone) INTO v_user_phone
        FROM public.users
        WHERE id = v_auth.user_id;

        -- Customer can only access order if user_id or phone matches
        SELECT * INTO v_order
        FROM public.orders
        WHERE id = p_order_id
          AND (user_id = v_auth.user_id OR (v_user_phone IS NOT NULL AND phone = v_user_phone));
    ELSE
        -- Staff can access any order
        SELECT * INTO v_order
        FROM public.orders
        WHERE id = p_order_id;
    END IF;

    IF v_order IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND_OR_UNAUTHORIZED');
    END IF;

    SELECT jsonb_agg(
        jsonb_build_object(
            'id', oi.id,
            'product_id', oi.product_id,
            'product_name', oi.product_name,
            'quantity', oi.quantity,
            'price', oi.price,
            'variant_name', oi.variant_name,
            'addons', oi.addons
        )
    ) INTO v_items
    FROM public.order_items oi
    WHERE oi.order_id = v_order.id;

    RETURN jsonb_build_object(
        'success', true,
        'order', jsonb_build_object(
            'id', v_order.id,
            'customer_name', v_order.customer_name,
            'phone', v_order.phone,
            'address', v_order.address,
            'landmark', v_order.landmark,
            'status', v_order.status,
            'order_status', v_order.order_status,
            'payment_status', v_order.payment_status,
            'payment_method', v_order.payment_method,
            'subtotal', v_order.subtotal,
            'gst', v_order.gst,
            'delivery_fee', v_order.delivery_fee,
            'total', v_order.total,
            'delivery_mode', v_order.delivery_mode,
            'created_at', v_order.created_at,
            'estimated_time_minutes', v_order.estimated_time_minutes,
            'latitude', v_order.latitude,
            'longitude', v_order.longitude,
            'google_map_link', v_order.google_map_link,
            'items', COALESCE(v_items, '[]'::jsonb)
        )
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_list_customers_admin(p_session_token text, p_search text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_customers JSONB;
    v_term TEXT;
BEGIN
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF NOT v_auth.is_valid THEN
        RETURN jsonb_build_object('success', false, 'error', v_auth.error_code);
    END IF;

    IF v_auth.role NOT IN ('admin', 'manager', 'cashier', 'staff', 'super_admin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;

    v_term := TRIM(COALESCE(p_search, ''));

    SELECT jsonb_agg(
        jsonb_build_object(
            'id', c.id,
            'name', c.name,
            'mobile', c.mobile,
            'email', c.email,
            'total_orders', COALESCE(c.total_orders, 0),
            'total_spent', COALESCE(c.total_spent, 0),
            'last_order_date', c.last_order_date,
            'source', c.source,
            'created_at', c.created_at
        ) ORDER BY c.id DESC
    ) INTO v_customers
    FROM public.customers c
    WHERE v_term = '' OR c.name ILIKE '%' || v_term || '%' OR c.mobile ILIKE '%' || v_term || '%';

    RETURN jsonb_build_object(
        'success', true,
        'customers', COALESCE(v_customers, '[]'::jsonb)
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_get_pos_customer(p_phone text, p_session_token text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_clean_phone TEXT;
    v_cust RECORD;
BEGIN
    -- 1. Token is mandatory (the DEFAULT NULL is kept only so the existing
    --    signature/callers do not change; a missing token is rejected).
    IF p_session_token IS NULL OR TRIM(p_session_token) = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'EMPTY_TOKEN');
    END IF;

    -- 2. Authoritative staff session validation.
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF v_auth.is_valid IS NOT TRUE THEN
        RETURN jsonb_build_object('success', false, 'error', COALESCE(v_auth.error_code, 'INVALID_TOKEN'));
    END IF;

    -- 3. Role gate: POS terminal customer lookup only.
    IF v_auth.role IS NULL OR v_auth.role NOT IN ('super_admin', 'admin', 'manager', 'pos_staff') THEN
        RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;

    -- 4. Lookup (unchanged from 20260921160000).
    v_clean_phone := TRIM(COALESCE(p_phone, ''));
    IF v_clean_phone LIKE '+91%' THEN
        v_clean_phone := substring(v_clean_phone from 4);
    END IF;
    v_clean_phone := REGEXP_REPLACE(v_clean_phone, '\D', '', 'g');

    IF v_clean_phone = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_PHONE');
    END IF;

    SELECT id, name, mobile, email, total_orders, total_spent, last_order_date
    INTO v_cust
    FROM public.customers
    WHERE mobile = v_clean_phone
    LIMIT 1;

    IF v_cust IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'CUSTOMER_NOT_FOUND');
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'customer', jsonb_build_object(
            'id', v_cust.id,
            'name', v_cust.name,
            'mobile', v_cust.mobile,
            'email', v_cust.email,
            'total_orders', COALESCE(v_cust.total_orders, 0),
            'total_spent', COALESCE(v_cust.total_spent, 0),
            'last_order_date', v_cust.last_order_date
        )
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_get_pos_orders_admin(p_session_token text, p_status text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_orders JSONB;
    v_status_filter TEXT;
BEGIN
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF NOT v_auth.is_valid THEN
        RETURN jsonb_build_object('success', false, 'error', v_auth.error_code);
    END IF;

    IF lower(v_auth.role) NOT IN ('admin', 'manager', 'cashier', 'kitchen', 'staff', 'pos_staff', 'super_admin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;

    v_status_filter := TRIM(COALESCE(p_status, ''));

    SELECT jsonb_agg(
        jsonb_build_object(
            'id', po.id,
            'order_number', po.order_number,
            'delivery_mode', po.delivery_mode,
            'table_id', po.table_id,
            'table_session_id', po.table_session_id,
            'customer_name', po.customer_name,
            'phone', po.phone,
            'subtotal', po.subtotal,
            'gst', po.gst,
            'total', po.total,
            'status', po.status,
            'payment_status', po.payment_status,
            'payment_method', po.payment_method,
            'created_at', po.created_at,
            'business_date', po.business_date,
            'offline_sync_id', po.offline_sync_id,
            'razorpay_order_id', po.razorpay_order_id
        ) ORDER BY po.id DESC
    ) INTO v_orders
    FROM public.pos_orders po
    WHERE v_status_filter = '' OR po.status ILIKE v_status_filter;

    RETURN jsonb_build_object(
        'success', true,
        'orders', COALESCE(v_orders, '[]'::jsonb)
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_get_pos_order_items_admin(
    p_session_token text,
    p_order_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_items JSONB;
BEGIN
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF NOT v_auth.is_valid THEN
        RETURN jsonb_build_object('success', false, 'error', v_auth.error_code);
    END IF;

    IF v_auth.role NOT IN ('admin', 'manager', 'cashier', 'kitchen', 'staff', 'pos_staff', 'super_admin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;

    SELECT jsonb_agg(
        jsonb_build_object(
            'id', poi.id,
            'order_id', poi.order_id,
            'session_item_id', poi.session_item_id,
            'product_id', poi.product_id,
            'product_name', poi.product_name,
            'quantity', poi.quantity,
            'price', poi.price,
            'total', poi.total,
            'variant_name', poi.variant_name,
            'addons', poi.addons,
            'status', poi.status,
            'item_discount_type', poi.item_discount_type,
            'item_discount_value', poi.item_discount_value,
            'item_discount_amount', poi.item_discount_amount,
            'item_discount_reason', poi.item_discount_reason,
            'item_final_price', poi.item_final_price
        )
    ) INTO v_items
    FROM public.pos_order_items poi
    WHERE p_order_id IS NULL OR poi.order_id = p_order_id;

    RETURN jsonb_build_object(
        'success', true,
        'items', COALESCE(v_items, '[]'::jsonb)
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_get_pos_tables(p_session_token text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_tables JSONB;
    v_is_staff BOOLEAN := FALSE;
BEGIN
    IF p_session_token IS NOT NULL AND TRIM(p_session_token) <> '' THEN
        SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
        IF v_auth.is_valid AND v_auth.role IN ('admin', 'manager', 'cashier', 'kitchen', 'staff', 'pos_staff', 'super_admin') THEN
            v_is_staff := TRUE;
        END IF;
    END IF;

    IF v_is_staff THEN
        SELECT jsonb_agg(
            jsonb_build_object(
                'id', t.id,
                'table_number', t.table_number,
                'name', t.name,
                'area', t.area,
                'capacity', t.capacity,
                'status', t.status,
                'active_order_id', t.active_order_id,
                'active_session_id', t.active_session_id,
                'created_at', t.created_at,
                'qr_token', t.qr_token,
                'qr_enabled', t.qr_enabled,
                'last_generated', t.last_generated
            ) ORDER BY t.id ASC
        ) INTO v_tables
        FROM public.pos_tables t;
    ELSE
        -- Minimal safe public view for QR discovery (unchanged: no
        -- active_session_id, no customer info, and -- as of this
        -- migration -- still explicitly no qr_token/qr_enabled either,
        -- since those are security-sensitive and this branch serves
        -- unauthenticated callers).
        SELECT jsonb_agg(
            jsonb_build_object(
                'id', t.id,
                'table_number', t.table_number,
                'name', t.name,
                'capacity', t.capacity,
                'status', t.status
            ) ORDER BY t.id ASC
        ) INTO v_tables
        FROM public.pos_tables t;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'tables', COALESCE(v_tables, '[]'::jsonb)
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_get_table_sessions_admin(p_session_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_sessions JSONB;
BEGIN
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF NOT v_auth.is_valid THEN
        RETURN jsonb_build_object('success', false, 'error', v_auth.error_code);
    END IF;

    IF v_auth.role NOT IN ('admin', 'manager', 'cashier', 'kitchen', 'staff', 'pos_staff', 'super_admin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;

    SELECT jsonb_agg(
        jsonb_build_object(
            'id', ts.id,
            'table_id', ts.table_id,
            'status', ts.status,
            'payment_status', ts.payment_status,
            'started_at', ts.started_at,
            'closed_at', ts.closed_at
        ) ORDER BY ts.id DESC
    ) INTO v_sessions
    FROM public.table_sessions ts;

    RETURN jsonb_build_object(
        'success', true,
        'sessions', COALESCE(v_sessions, '[]'::jsonb)
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_get_pos_notifications(p_session_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_notifs JSONB;
BEGIN
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF NOT v_auth.is_valid THEN
        RETURN jsonb_build_object('success', false, 'error', v_auth.error_code);
    END IF;

    IF v_auth.role NOT IN ('super_admin', 'admin', 'manager', 'pos_staff', 'kitchen_staff') THEN
        RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;

    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id', n.id,
            'table_id', n.table_id,
            'type', n.type,
            'status', n.status,
            'created_at', n.created_at
        ) ORDER BY n.id DESC
    ), '[]'::jsonb)
    INTO v_notifs
    FROM (
        SELECT * FROM public.pos_table_notifications
        ORDER BY created_at DESC
        LIMIT 100
    ) n;

    RETURN jsonb_build_object(
        'success', true,
        'notifications', v_notifs
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_get_delivery_orders_admin(p_session_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_orders JSONB;
BEGIN
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF NOT v_auth.is_valid THEN
        RETURN jsonb_build_object('success', false, 'error', v_auth.error_code);
    END IF;

    IF v_auth.role NOT IN ('admin', 'manager', 'cashier', 'kitchen', 'staff', 'pos_staff', 'super_admin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;

    SELECT jsonb_agg(
        jsonb_build_object(
            'id', del_ord.id,
            'order_number', del_ord.order_number,
            'customer_name', del_ord.customer_name,
            'mobile', del_ord.mobile,
            'address', del_ord.address,
            'grand_total', del_ord.grand_total,
            'status', del_ord.status,
            'payment_status', del_ord.payment_status,
            'created_at', del_ord.created_at
        ) ORDER BY del_ord.id DESC
    ) INTO v_orders
    FROM public.delivery_orders del_ord;

    RETURN jsonb_build_object(
        'success', true,
        'orders', COALESCE(v_orders, '[]'::jsonb)
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_get_delivery_order_items_admin(p_session_token text, p_order_id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_items JSONB;
BEGIN
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF NOT v_auth.is_valid THEN
        RETURN jsonb_build_object('success', false, 'error', v_auth.error_code);
    END IF;

    IF v_auth.role NOT IN ('admin', 'manager', 'cashier', 'kitchen', 'staff', 'pos_staff', 'super_admin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;

    SELECT jsonb_agg(
        jsonb_build_object(
            'id', doi.id,
            'order_id', doi.order_id,
            'product_id', doi.product_id,
            'product_name', doi.product_name,
            'qty', doi.qty,
            'price', doi.price
        )
    ) INTO v_items
    FROM public.delivery_order_items doi
    WHERE p_order_id IS NULL OR doi.order_id = p_order_id;

    RETURN jsonb_build_object(
        'success', true,
        'items', COALESCE(v_items, '[]'::jsonb)
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_get_pay_transactions_admin(p_session_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_txs JSONB;
BEGIN
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF NOT v_auth.is_valid THEN
        RETURN jsonb_build_object('success', false, 'error', v_auth.error_code);
    END IF;

    IF v_auth.role NOT IN ('admin', 'manager', 'super_admin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;

    SELECT jsonb_agg(
        jsonb_build_object(
            'id', pt.id,
            'transaction_no', pt.transaction_no,
            'order_id', pt.order_id,
            'amount', pt.amount,
            'status', pt.status,
            'provider_id', pt.provider_id,
            'created_at', pt.created_at
        ) ORDER BY pt.id DESC
    ) INTO v_txs
    FROM public.pay_transactions pt;

    RETURN jsonb_build_object(
        'success', true,
        'transactions', COALESCE(v_txs, '[]'::jsonb)
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_get_kot_corrections_admin(p_session_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_corrections JSONB;
BEGIN
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF NOT v_auth.is_valid THEN
        RETURN jsonb_build_object('success', false, 'error', v_auth.error_code);
    END IF;

    IF v_auth.role NOT IN ('admin', 'manager', 'cashier', 'kitchen', 'staff', 'pos_staff', 'super_admin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;

    SELECT jsonb_agg(
        jsonb_build_object(
            'id', kc.id,
            'correction_id', kc.correction_id,
            'order_id', kc.order_id,
            'product_name', kc.product_name,
            'variant_name', kc.variant_name,
            'old_qty', kc.old_qty,
            'new_qty', kc.new_qty,
            'delta_qty', kc.delta_qty,
            'reason', kc.reason,
            'cashier', kc.cashier,
            'created_at', kc.created_at
        ) ORDER BY kc.id DESC
    ) INTO v_corrections
    FROM public.kot_corrections kc;

    RETURN jsonb_build_object(
        'success', true,
        'corrections', COALESCE(v_corrections, '[]'::jsonb)
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_get_qr_session_status(p_table_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_table RECORD;
    v_session RECORD;
    v_session_age_ms NUMERIC;
    v_stale_grace_ms CONSTANT NUMERIC := 20 * 60 * 1000; -- 20 minutes -- matches WelcomeScreen.jsx's existing STALE_SESSION_GRACE_MS
    v_live_order_count INTEGER;
    v_occupied BOOLEAN := FALSE;
    v_active_session_id BIGINT := NULL;
BEGIN
    SELECT id, table_number, status, active_order_id, active_session_id
    INTO v_table
    FROM public.pos_tables
    WHERE id = p_table_id;

    IF v_table.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'TABLE_NOT_FOUND');
    END IF;

    IF v_table.active_session_id IS NOT NULL THEN
        -- Direct BIGINT equality -- see migration header re: proven column
        -- type. No session_token/string dual-shape resolution.
        SELECT id, table_id, status, started_at
        INTO v_session
        FROM public.table_sessions
        WHERE id = v_table.active_session_id;

        IF v_session.id IS NOT NULL AND v_session.status = 'active' THEN
            v_session_age_ms := EXTRACT(EPOCH FROM (NOW() - COALESCE(v_session.started_at, NOW()))) * 1000;

            IF v_session_age_ms <= v_stale_grace_ms THEN
                -- Within grace period -- treat as genuinely occupied even
                -- with zero orders yet (a customer who just verified and
                -- is still browsing the menu). Exact same grace-period
                -- reasoning as WelcomeScreen.jsx's own (previously dead)
                -- client-side check.
                v_occupied := TRUE;
                v_active_session_id := v_session.id;
            ELSE
                -- Old enough to be evaluated for staleness: an "active"
                -- session with zero still-open orders is stale, not
                -- occupied. Matches WelcomeScreen.jsx's own open-orders
                -- predicate exactly (table_session_id OR table_id match,
                -- same finalized-status literal set).
                SELECT COUNT(*) INTO v_live_order_count
                FROM public.pos_orders
                WHERE (table_session_id = v_session.id OR table_id = p_table_id)
                  AND status NOT IN ('Closed', 'Voided', 'Refunded', 'Cancelled');

                IF v_live_order_count > 0 THEN
                    v_occupied := TRUE;
                    v_active_session_id := v_session.id;
                ELSE
                    -- Self-heal, actually effective here (unlike
                    -- WelcomeScreen's own fire-and-forget raw .update()
                    -- calls, which have been silent no-ops under
                    -- table_sessions_update_deny_all / pos_tables_update_deny_all
                    -- since Sept 21): this function runs SECURITY DEFINER,
                    -- so it bypasses that RLS for these two narrow,
                    -- well-understood writes only.
                    UPDATE public.table_sessions
                       SET status = 'closed', closed_at = NOW()
                     WHERE id = v_session.id;

                    UPDATE public.pos_tables
                       SET status = 'available', active_order_id = NULL, active_session_id = NULL, guests = 0
                     WHERE id = p_table_id;

                    v_occupied := FALSE;
                END IF;
            END IF;
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'table', jsonb_build_object(
            'id', v_table.id,
            'table_number', v_table.table_number,
            'status', CASE WHEN v_occupied THEN 'occupied' ELSE v_table.status END,
            'active_order_id', v_table.active_order_id
        ),
        'occupancy', jsonb_build_object(
            'active', v_occupied,
            'table_session_id', v_active_session_id
        )
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_get_customer_account_state(
    p_phone TEXT
)
RETURNS JSONB AS $$
DECLARE
    v_clean_phone TEXT;
    v_user RECORD;
    v_customer RECORD;
BEGIN
    v_clean_phone := TRIM(COALESCE(p_phone, ''));
    IF v_clean_phone LIKE '+91%' THEN
        v_clean_phone := substring(v_clean_phone from 4);
    END IF;
    v_clean_phone := REGEXP_REPLACE(v_clean_phone, '\D', '', 'g');

    IF v_clean_phone = '' OR LENGTH(v_clean_phone) < 10 THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_PHONE', 'message', 'Valid 10-digit mobile number is required.');
    END IF;

    -- Check public.users
    SELECT id, pin_hash, name, full_name INTO v_user
    FROM public.users
    WHERE (phone = v_clean_phone OR mobile = v_clean_phone)
    ORDER BY id ASC
    LIMIT 1;

    -- ACTIVE: user row exists AND pin_hash is non-null/non-empty
    IF v_user.id IS NOT NULL AND v_user.pin_hash IS NOT NULL AND LENGTH(TRIM(v_user.pin_hash)) > 0 THEN
        RETURN jsonb_build_object(
            'success', true,
            'exists', true,
            'account_state', 'ACTIVE'
        );
    END IF;

    -- Check public.customers
    SELECT id, name INTO v_customer
    FROM public.customers
    WHERE mobile = v_clean_phone
    ORDER BY id ASC
    LIMIT 1;

    -- ACTIVATION_REQUIRED: profile exists in customers OR user row exists with null pin_hash
    IF v_customer.id IS NOT NULL OR v_user.id IS NOT NULL THEN
        RETURN jsonb_build_object(
            'success', true,
            'exists', true,
            'account_state', 'ACTIVATION_REQUIRED',
            'existing_name', COALESCE(v_customer.name, v_user.name, v_user.full_name, '')
        );
    END IF;

    -- NEW: No records exist
    RETURN jsonb_build_object(
        'success', true,
        'exists', false,
        'account_state', 'NEW'
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION public.secure_activate_migrated_customer(
    p_name TEXT,
    p_phone TEXT,
    p_pin TEXT
)
RETURNS JSONB AS $$
DECLARE
    v_clean_name TEXT;
    v_clean_phone TEXT;
    v_clean_pin TEXT;
    v_pin_hash TEXT;
    v_existing_user RECORD;
    v_existing_customer RECORD;
    v_user_id BIGINT;
    v_customer_token TEXT;
BEGIN
    v_clean_name := TRIM(COALESCE(p_name, 'Customer'));
    v_clean_phone := TRIM(COALESCE(p_phone, ''));
    v_clean_pin := TRIM(COALESCE(p_pin, ''));

    IF v_clean_phone LIKE '+91%' THEN
        v_clean_phone := substring(v_clean_phone from 4);
    END IF;
    v_clean_phone := REGEXP_REPLACE(v_clean_phone, '\D', '', 'g');

    IF v_clean_phone = '' OR LENGTH(v_clean_phone) < 10 THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_PHONE', 'message', 'Valid 10-digit mobile number is required.');
    END IF;

    IF LENGTH(v_clean_pin) <> 4 OR v_clean_pin !~ '^\d{4}$' THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_PIN', 'message', '4-digit numeric PIN is required.');
    END IF;

    -- Explicit lock on matching user row if present
    SELECT id, pin_hash, name, full_name INTO v_existing_user
    FROM public.users
    WHERE (phone = v_clean_phone OR mobile = v_clean_phone)
    ORDER BY id ASC
    LIMIT 1
    FOR UPDATE;

    -- Explicit lock on matching customer row if present
    SELECT id, name INTO v_existing_customer
    FROM public.customers
    WHERE mobile = v_clean_phone
    ORDER BY id ASC
    LIMIT 1
    FOR UPDATE;

    -- CASE A: User row exists with valid active PIN -> Reject re-activation
    IF v_existing_user.id IS NOT NULL AND v_existing_user.pin_hash IS NOT NULL AND LENGTH(TRIM(v_existing_user.pin_hash)) > 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'ALREADY_ACTIVE', 'message', 'Account is already active. Please log in using your PIN.');
    END IF;

    -- Hash PIN server-side using bcrypt
    v_pin_hash := extensions.crypt(v_clean_pin, extensions.gen_salt('bf', 10));

    -- CASE B: User row exists but pin_hash IS NULL/empty -> UPDATE EXISTING USERS ROW
    IF v_existing_user.id IS NOT NULL THEN
        UPDATE public.users
        SET 
            pin_hash = v_pin_hash,
            name = COALESCE(NULLIF(v_clean_name, ''), v_existing_user.name, v_existing_user.full_name, 'Customer'),
            full_name = COALESCE(NULLIF(v_clean_name, ''), v_existing_user.full_name, v_existing_user.name, 'Customer'),
            phone = v_clean_phone,
            mobile = v_clean_phone,
            status = 'active',
            updated_at = NOW()
        WHERE id = v_existing_user.id;

        v_user_id := v_existing_user.id;

    -- CASE C & D: No users row exists -> INSERT 1 NEW USERS ROW
    ELSE
        INSERT INTO public.users (
            name,
            full_name,
            phone,
            mobile,
            pin_hash,
            role,
            status,
            created_at,
            updated_at
        ) VALUES (
            v_clean_name,
            v_clean_name,
            v_clean_phone,
            v_clean_phone,
            v_pin_hash,
            'customer',
            'active',
            NOW(),
            NOW()
        )
        RETURNING id INTO v_user_id;
    END IF;

    -- Preserve / Update existing public.customers profile row without deletion or duplicate creation
    IF v_existing_customer.id IS NOT NULL THEN
        UPDATE public.customers
        SET 
            name = COALESCE(NULLIF(v_clean_name, ''), name, 'Customer'),
            updated_at = NOW()
        WHERE id = v_existing_customer.id;
    ELSE
        INSERT INTO public.customers (name, mobile, source, created_at, updated_at)
        VALUES (v_clean_name, v_clean_phone, 'WEBSITE', NOW(), NOW())
        ON CONFLICT (mobile) DO UPDATE SET updated_at = NOW();
    END IF;

    -- Issue active session token directly
    v_customer_token := encode(extensions.gen_random_bytes(32), 'hex');
    INSERT INTO public.active_sessions (
        user_id,
        token,
        device,
        ip_address,
        location,
        created_at,
        expires_at
    ) VALUES (
        v_user_id,
        v_customer_token,
        'Customer Website Browser',
        '127.0.0.1',
        'Online',
        NOW(),
        NOW() + INTERVAL '30 days'
    );

    RETURN jsonb_build_object(
        'success', true,
        'token', v_customer_token,
        'user', jsonb_build_object(
            'id', v_user_id,
            'name', v_clean_name,
            'full_name', v_clean_name,
            'phone', v_clean_phone,
            'mobile', v_clean_phone,
            'role', 'customer'
        )
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION public.secure_update_delivery_settings(
    p_session_token TEXT,
    p_opening_time TEXT DEFAULT '10:00',
    p_closing_time TEXT DEFAULT '23:00',
    p_delivery_charge NUMERIC DEFAULT 40,
    p_free_delivery_above NUMERIC DEFAULT 299,
    p_minimum_order NUMERIC DEFAULT 149,
    p_delivery_radius NUMERIC DEFAULT 8,
    p_delivery_time TEXT DEFAULT '30-40 mins',
    p_cod_enabled BOOLEAN DEFAULT true,
    p_gps_lat NUMERIC DEFAULT 27.800872,
    p_gps_lng NUMERIC DEFAULT 76.648441,
    p_distance_slabs JSONB DEFAULT '[]'::jsonb
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_auth RECORD;
    v_existing_id BIGINT;
    v_updated RECORD;
BEGIN
    -- 1. Validate session token via CheesyOS internal auth helper
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF NOT v_auth.is_valid THEN
        RETURN jsonb_build_object('success', false, 'error', v_auth.error_code);
    END IF;

    -- 2. Authorize only approved Admin roles (super_admin, admin)
    IF v_auth.role NOT IN ('admin', 'super_admin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;

    -- 3. Resolve existing row ID
    SELECT id INTO v_existing_id
    FROM public.delivery_settings
    ORDER BY id ASC
    LIMIT 1;

    -- 4. Update or Insert delivery settings
    IF v_existing_id IS NOT NULL THEN
        UPDATE public.delivery_settings
        SET
            opening_time = COALESCE(p_opening_time, '10:00'),
            closing_time = COALESCE(p_closing_time, '23:00'),
            delivery_charge = COALESCE(p_delivery_charge, 0),
            free_delivery_above = COALESCE(p_free_delivery_above, 0),
            minimum_order = COALESCE(p_minimum_order, 0),
            delivery_radius = COALESCE(p_delivery_radius, 0),
            delivery_time = COALESCE(p_delivery_time, '30-40 mins'),
            cod_enabled = COALESCE(p_cod_enabled, true),
            gps_lat = COALESCE(p_gps_lat, 27.800872),
            gps_lng = COALESCE(p_gps_lng, 76.648441),
            distance_slabs = COALESCE(p_distance_slabs, '[]'::jsonb)
        WHERE id = v_existing_id
        RETURNING * INTO v_updated;
    ELSE
        INSERT INTO public.delivery_settings (
            opening_time,
            closing_time,
            delivery_charge,
            free_delivery_above,
            minimum_order,
            delivery_radius,
            delivery_time,
            cod_enabled,
            gps_lat,
            gps_lng,
            distance_slabs
        ) VALUES (
            COALESCE(p_opening_time, '10:00'),
            COALESCE(p_closing_time, '23:00'),
            COALESCE(p_delivery_charge, 0),
            COALESCE(p_free_delivery_above, 0),
            COALESCE(p_minimum_order, 0),
            COALESCE(p_delivery_radius, 0),
            COALESCE(p_delivery_time, '30-40 mins'),
            COALESCE(p_cod_enabled, true),
            COALESCE(p_gps_lat, 27.800872),
            COALESCE(p_gps_lng, 76.648441),
            COALESCE(p_distance_slabs, '[]'::jsonb)
        )
        RETURNING * INTO v_updated;
    END IF;

    RETURN jsonb_build_object('success', true, 'data', to_jsonb(v_updated));
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_release_pos_table(
    p_session_token TEXT,
    p_table_id BIGINT,
    p_order_id TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
    v_auth RECORD;
    v_table RECORD;
    v_session RECORD;
    v_order_id_clean TEXT;
    v_matched_order RECORD;
    v_is_owner_match BOOLEAN := FALSE;
    v_recovered_partial_state BOOLEAN := FALSE;
BEGIN
    -- 1. Validate caller session token internally
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF v_auth.is_valid IS NOT TRUE THEN
        RETURN jsonb_build_object('success', false, 'error', COALESCE(v_auth.error_code, 'INVALID_SESSION'));
    END IF;

    -- 2. Enforce Role Authorization (Tightened: pos_staff, manager, admin, super_admin ONLY)
    IF v_auth.role IS NULL OR lower(v_auth.role) IN ('customer', 'user', 'guest') OR lower(v_auth.role) NOT IN ('pos_staff', 'manager', 'admin', 'super_admin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'UNAUTHORIZED_ROLE');
    END IF;

    -- 3. Validate Inputs
    IF p_table_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_TABLE_ID');
    END IF;

    v_order_id_clean := trim(COALESCE(p_order_id, ''));
    IF v_order_id_clean = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_ORDER_ID');
    END IF;

    -- 4. Lock Table Row FOR UPDATE
    SELECT * INTO v_table
    FROM public.pos_tables
    WHERE id = p_table_id
    FOR UPDATE;

    IF v_table.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'TABLE_NOT_FOUND');
    END IF;

    -- 5. Idempotent Already-Released Check
    IF (v_table.status = 'available' OR v_table.status IS NULL)
       AND v_table.active_order_id IS NULL
       AND v_table.active_session_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', true,
            'already_released', true,
            'table_id', p_table_id
        );
    END IF;

    -- 6. Ownership Validation
    IF v_table.active_order_id IS NOT NULL THEN
        IF v_table.active_order_id::text = v_order_id_clean THEN
            v_is_owner_match := TRUE;
        ELSE
            -- Try matching cloud pos_orders record by id (numeric) or offline_sync_id
            SELECT id, offline_sync_id INTO v_matched_order
            FROM public.pos_orders
            WHERE (id::text = v_order_id_clean OR offline_sync_id = v_order_id_clean)
            LIMIT 1;

            IF v_matched_order.id IS NOT NULL AND (
                v_table.active_order_id::text = v_matched_order.id::text OR
                v_table.active_order_id::text = v_matched_order.offline_sync_id
            ) THEN
                v_is_owner_match := TRUE;
            END IF;
        END IF;

        IF NOT v_is_owner_match THEN
            RETURN jsonb_build_object(
                'success', false,
                'error', 'TABLE_OWNERSHIP_CONFLICT',
                'message', 'Table active order does not match requested order.'
            );
        END IF;
    END IF;

    -- 7. Session Resolution & Locking
    IF v_table.active_session_id IS NOT NULL THEN
        -- Check if active_session_id is a numeric string/bigint or session_token string
        SELECT * INTO v_session
        FROM public.table_sessions
        WHERE (
            (v_table.active_session_id ~ '^\d+$' AND id = v_table.active_session_id::bigint) OR
            session_token = v_table.active_session_id::text
        )
        FOR UPDATE;

        IF v_session.id IS NOT NULL THEN
            -- Verify table_id correlation
            IF v_session.table_id <> p_table_id THEN
                RETURN jsonb_build_object(
                    'success', false,
                    'error', 'SESSION_TABLE_MISMATCH',
                    'message', 'Session table ID mismatch.'
                );
            END IF;

            -- Case A: Session row exists but is ALREADY CLOSED
            IF lower(COALESCE(v_session.status, '')) = 'closed' THEN
                v_recovered_partial_state := TRUE;
            ELSE
                -- Normal Release: Close active session
                UPDATE public.table_sessions
                SET status = 'closed',
                    closed_at = NOW()
                WHERE id = v_session.id;
            END IF;
        ELSE
            -- Case E: Session pointer references nonexistent session row
            v_recovered_partial_state := TRUE;
        END IF;
    ELSE
        -- Case B: active_session_id is NULL while table is occupied
        v_recovered_partial_state := TRUE;
    END IF;

    -- 8. Atomic Table Pointer Reset & State Release
    UPDATE public.pos_tables
    SET status = 'available',
        active_order_id = NULL,
        active_session_id = NULL,
        guests = 0,
        merged_with = NULL,
        updated_at = NOW()
    WHERE id = p_table_id;

    -- 9. Transactional Notification Dispatch
    INSERT INTO public.pos_table_notifications (
        table_id,
        table_number,
        session_id,
        type,
        status,
        created_at
    ) VALUES (
        p_table_id,
        v_table.name,
        v_table.active_session_id,
        'table_status_update',
        'seen',
        NOW()
    );

    RETURN jsonb_build_object(
        'success', true,
        'already_released', false,
        'table_id', p_table_id,
        'recovered_partial_state', v_recovered_partial_state
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_save_kot_event(
    p_session_token text,
    p_payload jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_kot_event_id UUID;
    v_order_id BIGINT;
    v_offline_sync_id TEXT;
    v_payload_table_id BIGINT;
    v_table_session_id BIGINT;
    v_kot_type TEXT;
    v_cashier_name TEXT;
    v_items_json JSONB;
    
    v_existing_kot RECORD;
    v_existing_items_jsonb JSONB;
    v_incoming_items_jsonb JSONB;
    v_header_matches BOOLEAN;
    
    v_order RECORD;
    v_session RECORD;
    v_authoritative_table_id BIGINT;
    v_next_kot_num INT;
    
    v_item_elem JSONB;
    v_session_item_id UUID;
    v_product_id BIGINT;
    v_product_name TEXT;
    v_qty NUMERIC;
    v_variant TEXT;
    v_addons JSONB;
    v_notes TEXT;
    v_price NUMERIC;
    v_meal_cfg JSONB;
    v_item_ordinal INT;
    
    v_persisted_items JSONB;
BEGIN
    -- 1. Validate Session Token
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF NOT v_auth.is_valid THEN
        RETURN jsonb_build_object('success', false, 'error', v_auth.error_code);
    END IF;

    -- 2. Validate Authorization Roles
    IF v_auth.role NOT IN ('admin', 'manager', 'pos_staff', 'super_admin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;

    -- 3. Parse & Validate Payload
    IF p_payload IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_PAYLOAD');
    END IF;

    BEGIN
        v_kot_event_id := (p_payload->>'kot_event_id')::UUID;
    EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_KOT_EVENT_ID');
    END;

    IF v_kot_event_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'MISSING_KOT_EVENT_ID');
    END IF;

    v_order_id := CASE WHEN (p_payload->>'order_id') ~ '^\d+$' THEN (p_payload->>'order_id')::BIGINT ELSE NULL END;
    v_offline_sync_id := NULLIF(TRIM(p_payload->>'offline_sync_id'), '');

    v_payload_table_id := CASE WHEN (p_payload->>'table_id') ~ '^\d+$' THEN (p_payload->>'table_id')::BIGINT ELSE NULL END;
    v_table_session_id := CASE WHEN (p_payload->>'table_session_id') ~ '^\d+$' THEN (p_payload->>'table_session_id')::BIGINT ELSE NULL END;
    v_kot_type := COALESCE(NULLIF(p_payload->>'kot_type', ''), 'Normal');
    v_cashier_name := p_payload->>'cashier_name';
    v_items_json := p_payload->'items';

    IF v_items_json IS NULL OR jsonb_typeof(v_items_json) <> 'array' OR jsonb_array_length(v_items_json) = 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'EMPTY_KOT_ITEMS');
    END IF;

    -- 4. Resolve Target Order & Validate Identity First (To resolve authoritative identities for idempotency & validation)
    IF v_order_id IS NOT NULL THEN
        SELECT * INTO v_order FROM public.pos_orders WHERE id = v_order_id FOR UPDATE;
    ELSIF v_offline_sync_id IS NOT NULL THEN
        SELECT * INTO v_order FROM public.pos_orders WHERE offline_sync_id = v_offline_sync_id FOR UPDATE;
    ELSE
        RETURN jsonb_build_object('success', false, 'error', 'MISSING_ORDER_IDENTIFIER');
    END IF;

    IF v_order.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
    END IF;

    IF v_order_id IS NOT NULL AND v_offline_sync_id IS NOT NULL THEN
        IF v_order.offline_sync_id IS DISTINCT FROM v_offline_sync_id THEN
            RETURN jsonb_build_object('success', false, 'error', 'ORDER_IDENTITY_MISMATCH');
        END IF;
    END IF;

    -- 5. Session Status & Lock Parent Session Row
    IF v_table_session_id IS NULL THEN
        v_table_session_id := v_order.table_session_id;
    END IF;

    IF v_table_session_id IS NOT NULL THEN
        IF v_order.table_session_id IS NOT NULL AND v_order.table_session_id <> v_table_session_id THEN
            RETURN jsonb_build_object('success', false, 'error', 'SESSION_ORDER_MISMATCH');
        END IF;
        
        SELECT * INTO v_session FROM public.table_sessions WHERE id = v_table_session_id FOR UPDATE;
        IF v_session.id IS NULL OR lower(COALESCE(v_session.status, '')) IN ('closed', 'voided', 'completed', 'cancelled') OR v_session.closed_at IS NOT NULL THEN
            RETURN jsonb_build_object('success', false, 'error', 'SESSION_NOT_ACTIVE');
        END IF;
    END IF;

    -- 6. Table ID Authority Resolution & Validation
    v_authoritative_table_id := COALESCE(v_order.table_id, v_session.table_id);
    IF v_payload_table_id IS NOT NULL AND v_authoritative_table_id IS NOT NULL THEN
        IF v_payload_table_id <> v_authoritative_table_id THEN
            RETURN jsonb_build_object('success', false, 'error', 'TABLE_ID_MISMATCH');
        END IF;
    END IF;
    IF v_authoritative_table_id IS NULL THEN
        v_authoritative_table_id := v_payload_table_id;
    END IF;

    -- 7. Full Logical Payload Idempotency Check
    SELECT * INTO v_existing_kot FROM public.pos_kots WHERE kot_event_id = v_kot_event_id;
    IF v_existing_kot.id IS NOT NULL THEN
        -- Header Field Comparison
        v_header_matches := (
            v_existing_kot.order_id = v_order.id AND
            v_existing_kot.table_session_id IS NOT DISTINCT FROM v_table_session_id AND
            v_existing_kot.table_id IS NOT DISTINCT FROM v_authoritative_table_id AND
            v_existing_kot.kot_type = v_kot_type
        );

        IF NOT v_header_matches THEN
            RETURN jsonb_build_object('success', false, 'error', 'IDEMPOTENCY_PAYLOAD_MISMATCH');
        END IF;

        -- Construct Stored Items Canonical JSONB Array
        SELECT jsonb_agg(
            jsonb_build_object(
                'session_item_id', ki.session_item_id,
                'item_ordinal', ki.item_ordinal,
                'product_id', ki.product_id,
                'product_name', ki.product_name,
                'quantity', ki.quantity,
                'variant', ki.variant,
                'addons', COALESCE(ki.addons, '[]'::jsonb),
                'notes', ki.notes,
                'price', ki.price,
                'meal_configurations', COALESCE(ki.meal_configurations, 'null'::jsonb)
            ) ORDER BY ki.item_ordinal ASC, ki.session_item_id ASC
        ) INTO v_existing_items_jsonb
        FROM public.pos_kot_items ki
        WHERE ki.kot_event_id = v_kot_event_id;

        -- Construct Incoming Items Canonical JSONB Array
        SELECT jsonb_agg(
            jsonb_build_object(
                'session_item_id', (elem->>'session_item_id')::UUID,
                'item_ordinal', COALESCE((elem->>'item_ordinal')::INT, idx),
                'product_id', CASE WHEN (elem->>'product_id') ~ '^\d+$' THEN (elem->>'product_id')::BIGINT ELSE NULL END,
                'product_name', COALESCE(NULLIF(elem->>'product_name', ''), elem->>'name'),
                'quantity', (elem->>'quantity')::NUMERIC,
                'variant', COALESCE(elem->>'variant', 'Regular'),
                'addons', COALESCE(elem->'addons', '[]'::jsonb),
                'notes', COALESCE(elem->>'notes', ''),
                'price', COALESCE((elem->>'price')::NUMERIC, 0),
                'meal_configurations', COALESCE(elem->'meal_configurations', 'null'::jsonb)
            ) ORDER BY COALESCE((elem->>'item_ordinal')::INT, idx) ASC, (elem->>'session_item_id')::UUID ASC
        ) INTO v_incoming_items_jsonb
        FROM jsonb_array_elements(v_items_json) WITH ORDINALITY AS arr(elem, idx);

        IF v_existing_items_jsonb IS DISTINCT FROM v_incoming_items_jsonb THEN
            RETURN jsonb_build_object('success', false, 'error', 'IDEMPOTENCY_PAYLOAD_MISMATCH');
        END IF;

        -- Fetch persisted items for response parity
        SELECT jsonb_agg(
            jsonb_build_object(
                'id', ki.id,
                'session_item_id', ki.session_item_id,
                'product_id', ki.product_id,
                'product_name', ki.product_name,
                'quantity', ki.quantity,
                'variant', ki.variant,
                'addons', ki.addons,
                'notes', ki.notes,
                'price', ki.price,
                'meal_configurations', ki.meal_configurations,
                'created_at', ki.created_at
            ) ORDER BY ki.id ASC
        ) INTO v_persisted_items
        FROM public.pos_kot_items ki
        WHERE ki.kot_event_id = v_kot_event_id;

        RETURN jsonb_build_object(
            'success', true,
            'idempotent_retry', true,
            'kot_event_id', v_existing_kot.kot_event_id,
            'kot_number', v_existing_kot.kot_number,
            'order_id', v_existing_kot.order_id,
            'offline_sync_id', v_existing_kot.offline_sync_id,
            'table_id', v_existing_kot.table_id,
            'table_session_id', v_existing_kot.table_session_id,
            'kot_type', v_existing_kot.kot_type,
            'cashier_name', v_existing_kot.cashier_name,
            'created_at', v_existing_kot.created_at,
            'items', COALESCE(v_persisted_items, '[]'::jsonb)
        );
    END IF;

    -- 8. Atomic KOT Number Allocation (Inside FOR UPDATE lock scope)
    IF v_table_session_id IS NOT NULL THEN
        SELECT COALESCE(MAX(kot_number), 0) + 1 INTO v_next_kot_num 
        FROM public.pos_kots 
        WHERE table_session_id = v_table_session_id;
    ELSE
        SELECT COALESCE(MAX(kot_number), 0) + 1 INTO v_next_kot_num 
        FROM public.pos_kots 
        WHERE order_id = v_order.id;
    END IF;

    -- 9. Insert KOT Header
    INSERT INTO public.pos_kots (
        kot_event_id,
        order_id,
        offline_sync_id,
        table_id,
        table_session_id,
        kot_number,
        kot_type,
        cashier_name,
        created_at
    ) VALUES (
        v_kot_event_id,
        v_order.id,
        v_order.offline_sync_id,
        v_authoritative_table_id,
        v_table_session_id,
        v_next_kot_num,
        v_kot_type,
        v_cashier_name,
        NOW()
    );

    -- 10. Insert KOT Items
    FOR i IN 0 .. (jsonb_array_length(v_items_json) - 1) LOOP
        v_item_elem := v_items_json->i;
        
        BEGIN
            v_session_item_id := (v_item_elem->>'session_item_id')::UUID;
        EXCEPTION WHEN OTHERS THEN
            RAISE EXCEPTION 'INVALID_ITEM_SESSION_ID';
        END;

        IF v_session_item_id IS NULL THEN
            RAISE EXCEPTION 'MISSING_ITEM_SESSION_ID';
        END IF;

        v_product_name := COALESCE(NULLIF(v_item_elem->>'product_name', ''), v_item_elem->>'name');
        IF v_product_name IS NULL THEN
            RAISE EXCEPTION 'MISSING_PRODUCT_NAME';
        END IF;

        v_qty := (v_item_elem->>'quantity')::NUMERIC;
        IF v_qty IS NULL OR v_qty <= 0 THEN
            RAISE EXCEPTION 'INVALID_QUANTITY';
        END IF;

        v_product_id := CASE WHEN (v_item_elem->>'product_id') ~ '^\d+$' THEN (v_item_elem->>'product_id')::BIGINT ELSE NULL END;
        v_variant := COALESCE(v_item_elem->>'variant', 'Regular');
        v_addons := COALESCE(v_item_elem->'addons', '[]'::jsonb);
        v_notes := COALESCE(v_item_elem->>'notes', '');
        v_price := COALESCE((v_item_elem->>'price')::NUMERIC, 0);
        v_meal_cfg := v_item_elem->'meal_configurations';
        v_item_ordinal := COALESCE((v_item_elem->>'item_ordinal')::INT, i + 1);

        INSERT INTO public.pos_kot_items (
            kot_event_id,
            session_item_id,
            item_ordinal,
            product_id,
            product_name,
            quantity,
            variant,
            addons,
            notes,
            price,
            meal_configurations,
            created_at
        ) VALUES (
            v_kot_event_id,
            v_session_item_id,
            v_item_ordinal,
            v_product_id,
            v_product_name,
            v_qty,
            v_variant,
            v_addons,
            v_notes,
            v_price,
            v_meal_cfg,
            NOW()
        );
    END LOOP;

    -- 11. Fetch and Return Canonical Event
    SELECT jsonb_agg(
        jsonb_build_object(
            'id', ki.id,
            'session_item_id', ki.session_item_id,
            'product_id', ki.product_id,
            'product_name', ki.product_name,
            'quantity', ki.quantity,
            'variant', ki.variant,
            'addons', ki.addons,
            'notes', ki.notes,
            'price', ki.price,
            'meal_configurations', ki.meal_configurations,
            'created_at', ki.created_at
        ) ORDER BY ki.id ASC
    ) INTO v_persisted_items
    FROM public.pos_kot_items ki
    WHERE ki.kot_event_id = v_kot_event_id;

    RETURN jsonb_build_object(
        'success', true,
        'kot_event_id', v_kot_event_id,
        'kot_number', v_next_kot_num,
        'order_id', v_order.id,
        'offline_sync_id', v_order.offline_sync_id,
        'table_id', v_authoritative_table_id,
        'table_session_id', v_table_session_id,
        'kot_type', v_kot_type,
        'cashier_name', v_cashier_name,
        'created_at', NOW(),
        'items', COALESCE(v_persisted_items, '[]'::jsonb)
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_get_kots_for_order(
    p_session_token text,
    p_order_id bigint DEFAULT NULL,
    p_offline_sync_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_target_order_id BIGINT;
    v_target_offline_sync_id TEXT;
    v_kots JSONB;
BEGIN
    -- 1. Validate Session Token
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF NOT v_auth.is_valid THEN
        RETURN jsonb_build_object('success', false, 'error', v_auth.error_code);
    END IF;

    -- 2. Validate Authorization Roles
    IF v_auth.role NOT IN ('admin', 'manager', 'pos_staff', 'super_admin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;

    -- 3. Enforce Bounded Search Identity (No NULL/NULL Bulk Table Dumping)
    IF p_order_id IS NULL AND (p_offline_sync_id IS NULL OR TRIM(p_offline_sync_id) = '') THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_ORDER_IDENTITY');
    END IF;

    -- 4. Resolve Target Order
    SELECT id, offline_sync_id INTO v_target_order_id, v_target_offline_sync_id
    FROM public.pos_orders
    WHERE (p_order_id IS NULL OR id = p_order_id)
      AND (p_offline_sync_id IS NULL OR TRIM(p_offline_sync_id) = '' OR offline_sync_id = TRIM(p_offline_sync_id));

    IF v_target_order_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
    END IF;

    -- 5. Build Aggregated Nested JSON
    SELECT jsonb_agg(
        jsonb_build_object(
            'kot_event_id', k.kot_event_id,
            'order_id', k.order_id,
            'offline_sync_id', k.offline_sync_id,
            'table_id', k.table_id,
            'table_session_id', k.table_session_id,
            'kot_number', k.kot_number,
            'kot_type', k.kot_type,
            'cashier_name', k.cashier_name,
            'created_at', k.created_at,
            'items', COALESCE(
                (
                    SELECT jsonb_agg(
                        jsonb_build_object(
                            'id', ki.id,
                            'session_item_id', ki.session_item_id,
                            'product_id', ki.product_id,
                            'product_name', ki.product_name,
                            'quantity', ki.quantity,
                            'variant', ki.variant,
                            'addons', ki.addons,
                            'notes', ki.notes,
                            'price', ki.price,
                            'meal_configurations', ki.meal_configurations,
                            'created_at', ki.created_at
                        ) ORDER BY ki.id ASC
                    )
                    FROM public.pos_kot_items ki
                    WHERE ki.kot_event_id = k.kot_event_id
                ), '[]'::jsonb
            )
        ) ORDER BY k.kot_number ASC, k.created_at ASC
    ) INTO v_kots
    FROM public.pos_kots k
    WHERE k.order_id = v_target_order_id;

    RETURN jsonb_build_object(
        'success', true,
        'kots', COALESCE(v_kots, '[]'::jsonb)
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_save_kot_correction(
    p_session_token text,
    p_payload jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_correction_id UUID;
    v_order_id BIGINT;
    v_offline_order_id TEXT;
    v_table_session_id BIGINT;
    v_kot_number TEXT;
    v_source_kot_id INT;
    v_line_id TEXT;
    v_edit_session_id TEXT;
    v_product_name TEXT;
    v_variant_name TEXT;
    v_addons JSONB;
    v_price NUMERIC;
    v_old_qty NUMERIC;
    v_new_qty NUMERIC;
    v_delta_qty NUMERIC;
    v_reason TEXT;
    v_cashier TEXT;
    v_created_at TIMESTAMPTZ;
    
    v_order RECORD;
    v_order_item RECORD;
    v_latest_ledger_new_qty NUMERIC;
    v_expected_old_qty NUMERIC;
    v_existing RECORD;
    v_is_identical BOOLEAN;
    v_inserted_id BIGINT;
BEGIN
    -- 1. Validate Session Token
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF NOT v_auth.is_valid THEN
        RETURN jsonb_build_object('success', false, 'error', v_auth.error_code);
    END IF;

    -- 2. Validate Authorization Roles
    IF v_auth.role NOT IN ('admin', 'manager', 'pos_staff', 'super_admin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;

    -- 3. Parse Payload
    IF p_payload IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_PAYLOAD');
    END IF;

    BEGIN
        v_correction_id := (p_payload->>'correction_id')::UUID;
    EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_CORRECTION_ID');
    END;

    IF v_correction_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'MISSING_CORRECTION_ID');
    END IF;

    v_order_id := CASE WHEN (p_payload->>'order_id') ~ '^\d+$' THEN (p_payload->>'order_id')::BIGINT ELSE NULL END;
    v_offline_order_id := NULLIF(TRIM(p_payload->>'offline_order_id'), '');
    v_table_session_id := CASE WHEN (p_payload->>'table_session_id') ~ '^\d+$' THEN (p_payload->>'table_session_id')::BIGINT ELSE NULL END;
    v_kot_number := NULLIF(TRIM(p_payload->>'kot_number'), '');
    v_source_kot_id := CASE WHEN (p_payload->>'source_kot_id') ~ '^\d+$' THEN (p_payload->>'source_kot_id')::INT ELSE NULL END;
    
    v_line_id := NULLIF(TRIM(p_payload->>'line_id'), '');
    v_edit_session_id := NULLIF(TRIM(p_payload->>'edit_session_id'), '');

    IF v_line_id IS NULL OR v_edit_session_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'MISSING_REQUIRED_FIELDS');
    END IF;

    v_addons := COALESCE(p_payload->'addons', '[]'::jsonb);

    BEGIN
        v_old_qty := (p_payload->>'old_qty')::NUMERIC;
        v_new_qty := (p_payload->>'new_qty')::NUMERIC;
        v_delta_qty := (p_payload->>'delta_qty')::NUMERIC;
    EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_QUANTITY_VALUES');
    END;

    IF v_old_qty IS NULL OR v_new_qty IS NULL OR v_delta_qty IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'MISSING_QUANTITY_FIELDS');
    END IF;

    -- 4. Strict Numeric Finite Domain Validation
    IF v_old_qty = 'NaN'::numeric OR v_old_qty = 'Infinity'::numeric OR v_old_qty = '-Infinity'::numeric OR
       v_new_qty = 'NaN'::numeric OR v_new_qty = 'Infinity'::numeric OR v_new_qty = '-Infinity'::numeric OR
       v_delta_qty = 'NaN'::numeric OR v_delta_qty = 'Infinity'::numeric OR v_delta_qty = '-Infinity'::numeric THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_QUANTITY_VALUES');
    END IF;

    -- 5. Quantity Direction & Invariant Verification
    IF v_old_qty < 0 OR v_new_qty < 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_QUANTITY_VALUES');
    END IF;

    IF v_new_qty > v_old_qty OR v_delta_qty > 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_QUANTITY_INCREASE');
    END IF;

    IF v_delta_qty <> (v_new_qty - v_old_qty) THEN
        RETURN jsonb_build_object('success', false, 'error', 'QUANTITY_INVARIANT_MISMATCH');
    END IF;

    v_reason := p_payload->>'reason';
    v_cashier := p_payload->>'cashier';
    
    IF (p_payload->>'created_at') IS NOT NULL AND TRIM(p_payload->>'created_at') <> '' THEN
        BEGIN
            v_created_at := (p_payload->>'created_at')::TIMESTAMPTZ;
        EXCEPTION WHEN OTHERS THEN
            v_created_at := NOW();
        END;
    ELSE
        v_created_at := NOW();
    END IF;

    -- 6. Resolve Target Order & Validate Identity
    IF v_order_id IS NOT NULL THEN
        SELECT * INTO v_order FROM public.pos_orders WHERE id = v_order_id;
    ELSIF v_offline_order_id IS NOT NULL THEN
        SELECT * INTO v_order FROM public.pos_orders WHERE offline_sync_id = v_offline_order_id;
    ELSE
        RETURN jsonb_build_object('success', false, 'error', 'MISSING_ORDER_IDENTIFIER');
    END IF;

    IF v_order.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
    END IF;

    IF v_order_id IS NOT NULL AND v_offline_order_id IS NOT NULL THEN
        IF v_order.offline_sync_id IS DISTINCT FROM v_offline_order_id THEN
            RETURN jsonb_build_object('success', false, 'error', 'ORDER_IDENTITY_MISMATCH');
        END IF;
    END IF;

    -- 7. Validate Table Session Correlation (if session id provided)
    IF v_table_session_id IS NOT NULL THEN
        IF v_order.table_session_id IS NOT NULL AND v_order.table_session_id <> v_table_session_id THEN
            RETURN jsonb_build_object('success', false, 'error', 'SESSION_ORDER_MISMATCH');
        END IF;
    END IF;

    -- 8. Authoritative Line Resolution & Line-Level Row Lock (pos_order_items)
    SELECT * INTO v_order_item FROM public.pos_order_items poi
    WHERE poi.order_id = v_order.id
      AND poi.session_item_id::text = v_line_id
    FOR UPDATE;

    IF v_order_item.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'LINE_ID_NOT_FOUND_ON_ORDER');
    END IF;

    -- SERVER OVERRIDE: Source Authoritative Price, Product Name, and Variant from Order Line
    v_product_name := v_order_item.product_name;
    v_variant_name := COALESCE(v_order_item.variant_name, 'Regular');
    v_price := COALESCE(v_order_item.price, 0);

    -- 9. Pre-Insert Idempotency Check
    SELECT * INTO v_existing FROM public.kot_corrections 
    WHERE correction_id = v_correction_id 
       OR (line_id = v_line_id AND edit_session_id = v_edit_session_id);

    IF v_existing.id IS NOT NULL THEN
        v_is_identical := (
            v_existing.order_id = v_order.id AND
            COALESCE(v_existing.table_session_id, -1) = COALESCE(v_table_session_id, v_order.table_session_id, -1) AND
            COALESCE(v_existing.kot_number, '') = COALESCE(v_kot_number, '') AND
            v_existing.line_id = v_line_id AND
            v_existing.edit_session_id = v_edit_session_id AND
            v_existing.product_name = v_product_name AND
            COALESCE(v_existing.variant_name, 'Regular') = v_variant_name AND
            COALESCE(v_existing.addons, '[]'::jsonb) = v_addons AND
            COALESCE(v_existing.price, 0) = v_price AND
            v_existing.old_qty = v_old_qty AND
            v_existing.new_qty = v_new_qty AND
            v_existing.delta_qty = v_delta_qty
        );

        IF v_is_identical THEN
            RETURN jsonb_build_object(
                'success', true,
                'idempotent_retry', true,
                'cloudRowId', v_existing.id,
                'correction_id', v_existing.correction_id
            );
        ELSE
            RETURN jsonb_build_object('success', false, 'error', 'IDEMPOTENCY_PAYLOAD_MISMATCH');
        END IF;
    END IF;

    -- 10. MODEL-B WRITER RULE: Deterministic Expected Old Qty Resolution
    -- Query latest prior correction in ledger for this line using server ID order
    SELECT c.new_qty INTO v_latest_ledger_new_qty
    FROM public.kot_corrections c
    WHERE c.order_id = v_order.id
      AND c.line_id = v_line_id
    ORDER BY c.id DESC
    LIMIT 1;

    IF v_latest_ledger_new_qty IS NOT NULL THEN
        v_expected_old_qty := v_latest_ledger_new_qty;
    ELSE
        v_expected_old_qty := v_order_item.quantity;
    END IF;

    IF v_old_qty <> v_expected_old_qty THEN
        RETURN jsonb_build_object('success', false, 'error', 'OLD_QTY_MISMATCH');
    END IF;

    -- 11. Append-Only Insert with Exception-Safe Race Recovery
    BEGIN
        INSERT INTO public.kot_corrections (
            correction_id,
            order_id,
            offline_order_id,
            table_session_id,
            kot_number,
            source_kot_id,
            line_id,
            edit_session_id,
            product_name,
            variant_name,
            addons,
            price,
            old_qty,
            new_qty,
            delta_qty,
            reason,
            cashier,
            created_at,
            synced_at
        ) VALUES (
            v_correction_id,
            v_order.id,
            v_order.offline_sync_id,
            COALESCE(v_table_session_id, v_order.table_session_id),
            v_kot_number,
            v_source_kot_id,
            v_line_id,
            v_edit_session_id,
            v_product_name,
            v_variant_name,
            v_addons,
            v_price,
            v_old_qty,
            v_new_qty,
            v_delta_qty,
            v_reason,
            v_cashier,
            v_created_at,
            NOW()
        ) RETURNING id INTO v_inserted_id;

        -- 12. MODEL-B ATOMIC MIRROR PROJECTION
        -- Immediately project effective quantity and status to pos_order_items
        IF v_new_qty = 0 THEN
            UPDATE public.pos_order_items SET
                quantity = 0,
                total = 0.00,
                status = 'Rejected',
                rejection_reason = v_reason,
                is_modified = true,
                modified_reason = v_reason
            WHERE id = v_order_item.id;
        ELSE
            UPDATE public.pos_order_items SET
                quantity = v_new_qty,
                total = ROUND(v_price * v_new_qty, 2),
                is_modified = true,
                modified_reason = v_reason
            WHERE id = v_order_item.id;
        END IF;

        RETURN jsonb_build_object(
            'success', true,
            'idempotent_retry', false,
            'cloudRowId', v_inserted_id,
            'correction_id', v_correction_id
        );
    EXCEPTION WHEN unique_violation THEN
        -- Race Condition Handling
        SELECT * INTO v_existing FROM public.kot_corrections 
        WHERE correction_id = v_correction_id 
           OR (line_id = v_line_id AND edit_session_id = v_edit_session_id);

        IF v_existing.id IS NOT NULL THEN
            v_is_identical := (
                v_existing.order_id = v_order.id AND
                COALESCE(v_existing.table_session_id, -1) = COALESCE(v_table_session_id, v_order.table_session_id, -1) AND
                COALESCE(v_existing.kot_number, '') = COALESCE(v_kot_number, '') AND
                v_existing.line_id = v_line_id AND
                v_existing.edit_session_id = v_edit_session_id AND
                v_existing.product_name = v_product_name AND
                COALESCE(v_existing.variant_name, 'Regular') = v_variant_name AND
                COALESCE(v_existing.addons, '[]'::jsonb) = v_addons AND
                COALESCE(v_existing.price, 0) = v_price AND
                v_existing.old_qty = v_old_qty AND
                v_existing.new_qty = v_new_qty AND
                v_existing.delta_qty = v_delta_qty
            );

            IF v_is_identical THEN
                RETURN jsonb_build_object(
                    'success', true,
                    'idempotent_retry', true,
                    'cloudRowId', v_existing.id,
                    'correction_id', v_existing.correction_id
                );
            ELSE
                RETURN jsonb_build_object('success', false, 'error', 'IDEMPOTENCY_PAYLOAD_MISMATCH');
            END IF;
        ELSE
            RETURN jsonb_build_object('success', false, 'error', 'IDEMPOTENCY_PAYLOAD_MISMATCH');
        END IF;
    END;

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_get_kot_corrections_for_order(
    p_session_token text,
    p_order_id bigint DEFAULT NULL,
    p_offline_sync_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_offline_sync_id TEXT;
    v_target_order_id BIGINT;
    v_target_offline_sync_id TEXT;
    v_corrections JSONB;
BEGIN
    -- 1. Validate Session Token
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF NOT v_auth.is_valid THEN
        RETURN jsonb_build_object('success', false, 'error', v_auth.error_code);
    END IF;

    -- 2. Validate Authorization Roles
    IF v_auth.role NOT IN ('admin', 'manager', 'pos_staff', 'super_admin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;

    -- 3. Parse & Normalize Identifiers
    v_offline_sync_id := NULLIF(TRIM(p_offline_sync_id), '');

    -- 4. Bounded Identity Resolution & Validation
    IF p_order_id IS NOT NULL AND v_offline_sync_id IS NOT NULL THEN
        SELECT id, offline_sync_id INTO v_target_order_id, v_target_offline_sync_id
        FROM public.pos_orders
        WHERE id = p_order_id;
        
        IF v_target_order_id IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
        END IF;
        
        IF v_target_offline_sync_id IS DISTINCT FROM v_offline_sync_id THEN
            RETURN jsonb_build_object('success', false, 'error', 'ORDER_IDENTITY_MISMATCH');
        END IF;
    ELSIF p_order_id IS NOT NULL THEN
        SELECT id, offline_sync_id INTO v_target_order_id, v_target_offline_sync_id
        FROM public.pos_orders
        WHERE id = p_order_id;
        
        IF v_target_order_id IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
        END IF;
    ELSIF v_offline_sync_id IS NOT NULL THEN
        SELECT id, offline_sync_id INTO v_target_order_id, v_target_offline_sync_id
        FROM public.pos_orders
        WHERE offline_sync_id = v_offline_sync_id;
        
        IF v_target_order_id IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
        END IF;
    ELSE
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_ORDER_IDENTITY');
    END IF;

    -- 5. Query Order-Bounded Corrections
    SELECT jsonb_agg(
        jsonb_build_object(
            'correction_id', kc.correction_id,
            'order_id', kc.order_id,
            'offline_order_id', kc.offline_order_id,
            'table_session_id', kc.table_session_id,
            'kot_number', kc.kot_number,
            'source_kot_id', kc.source_kot_id,
            'line_id', kc.line_id,
            'edit_session_id', kc.edit_session_id,
            'product_name', kc.product_name,
            'variant_name', kc.variant_name,
            'addons', kc.addons,
            'price', kc.price,
            'old_qty', kc.old_qty,
            'new_qty', kc.new_qty,
            'delta_qty', kc.delta_qty,
            'reason', kc.reason,
            'cashier', kc.cashier,
            'created_at', kc.created_at
        ) ORDER BY kc.created_at ASC, kc.id ASC
    ) INTO v_corrections
    FROM public.kot_corrections kc
    WHERE kc.order_id = v_target_order_id;

    -- 6. Return Structured Envelope
    RETURN jsonb_build_object(
        'success', true,
        'order_id', v_target_order_id,
        'offline_sync_id', v_target_offline_sync_id,
        'corrections', COALESCE(v_corrections, '[]'::jsonb)
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_recover_orphaned_pos_table(
    p_session_token TEXT,
    p_table_id BIGINT,
    p_expected_active_order_id TEXT,
    p_expected_active_session_id BIGINT,
    p_reason TEXT DEFAULT 'Orphaned table/session recovery'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_user_name TEXT;
    v_table RECORD;
    v_session RECORD;
    v_reason TEXT;
    v_session_nonfinalized_count INTEGER := 0;
    v_pointer_match_count INTEGER := 0;
    v_pointer_nonfinalized_count INTEGER := 0;
    v_prev_active_order_id TEXT;
    v_prev_active_session_id BIGINT;
BEGIN
    -- 1. Validate caller session token internally (canonical hardened pattern, same
    -- helper used by secure_cancel_pos_order / secure_get_pos_orders_admin).
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF v_auth.is_valid IS NOT TRUE THEN
        RETURN jsonb_build_object('success', false, 'error', COALESCE(v_auth.error_code, 'INVALID_TOKEN'));
    END IF;

    -- 2. Enforce Role Authorization. Canonical elevated POS table-operation role set,
    -- identical to secure_release_pos_table's -- deliberately excludes
    -- cashier / kitchen / staffadmin / owner per this pass's explicit instruction, and
    -- does not trust any caller-supplied role (v_auth.role comes only from the validated
    -- session, never from the request payload).
    IF v_auth.role IS NULL OR lower(v_auth.role) NOT IN ('pos_staff', 'manager', 'admin', 'super_admin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'FORBIDDEN');
    END IF;

    -- 3. Validate Inputs. Expected pointer values are mandatory CAS inputs, not optional
    -- convenience fields -- a caller that doesn't know the table's current pointers has
    -- no business recovering it blind.
    IF p_table_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_TABLE_ID');
    END IF;

    IF p_expected_active_order_id IS NULL OR trim(p_expected_active_order_id) = ''
       OR p_expected_active_session_id IS NULL OR trim(p_expected_active_session_id) = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'MISSING_EXPECTED_STATE');
    END IF;

    v_reason := trim(regexp_replace(COALESCE(p_reason, ''), '\s+', ' ', 'g'));
    IF v_reason = '' OR length(v_reason) > 500 THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_REASON');
    END IF;

    -- 4. Lock Target Table Row FOR UPDATE
    SELECT * INTO v_table FROM public.pos_tables WHERE id = p_table_id FOR UPDATE;
    IF v_table.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'TABLE_NOT_FOUND');
    END IF;

    v_prev_active_order_id := v_table.active_order_id;
    v_prev_active_session_id := v_table.active_session_id;

    -- 5. Idempotent Already-Recovered Check (the CLEAN signature only: available status
    -- and both pointers null). A second identical call after a successful recovery lands
    -- here and returns success without touching anything.
    IF (v_table.status = 'available' OR v_table.status IS NULL)
       AND v_table.active_order_id IS NULL
       AND v_table.active_session_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', true,
            'already_recovered', true,
            'table_id', p_table_id
        );
    END IF;

    -- 6. Recheck Occupied-Orphan Precondition Shape. Anything that is neither the clean
    -- "already recovered" signature above NOR the clean "occupied with both pointers set"
    -- signature is an unexpected/changed state -- fail closed rather than guess. This is
    -- deliberately stricter than a plain CAS-only check: an occupied table with only ONE
    -- pointer null (a state this recovery primitive was never designed for) is also
    -- rejected here, not treated as recoverable.
    IF v_table.status IS DISTINCT FROM 'occupied'
       OR v_table.active_order_id IS NULL
       OR v_table.active_session_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'STALE_STATE_CONFLICT',
            'message', 'Table is no longer in the expected occupied-orphan shape.'
        );
    END IF;

    -- 7. CAS: the caller-supplied expected pointer values must still equal the row we
    -- just locked. An occupied table whose pointers have changed since the caller last
    -- read them is a conflict, not a recovery target -- never proceed on a guess.
    IF v_table.active_order_id::text IS DISTINCT FROM p_expected_active_order_id
       OR v_table.active_session_id IS DISTINCT FROM p_expected_active_session_id THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'STALE_STATE_CONFLICT',
            'message', 'Table pointers changed since the caller last read them.'
        );
    END IF;

    -- 8. Resolve & Lock the referenced table_sessions row. Pass 2F fresh live
    -- information_schema evidence proves pos_tables.active_session_id is BIGINT (NOT NULL
    -- column type), matching table_sessions.id's own type exactly -- it can never hold a
    -- session_token string, so the dual-shape regex-guarded text/bigint resolution this
    -- pass inherited from secure_release_pos_table (written against an earlier, unproven
    -- type assumption) has been removed as legacy complexity with no proven need here, per
    -- this pass's explicit instruction. A direct BIGINT equality is both correct and
    -- strictly safer: the removed `~ '^\d+$'` guard, applied to an actual bigint value,
    -- would have raised "operator does not exist: bigint ~ unknown" on first invocation.
    SELECT * INTO v_session
    FROM public.table_sessions
    WHERE id = v_table.active_session_id
    FOR UPDATE;

    IF v_session.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'SESSION_CONFLICT', 'message', 'Referenced table session not found.');
    END IF;

    -- Cross-table ownership guard (same check secure_void_table_session already performs).
    IF v_session.table_id IS DISTINCT FROM p_table_id THEN
        RETURN jsonb_build_object('success', false, 'error', 'SESSION_CONFLICT', 'message', 'Session does not belong to this table.');
    END IF;

    IF lower(COALESCE(v_session.status, '')) IS DISTINCT FROM 'active' THEN
        RETURN jsonb_build_object('success', false, 'error', 'SESSION_CONFLICT', 'message', 'Referenced session is not active.');
    END IF;

    -- 9. ORPHAN PROOF -- CHECK 1 (ACTIVE SESSION): zero non-finalized pos_orders linked to
    -- the current active_session_id. The finalized-status set is copied verbatim from
    -- secure_cancel_pos_order's own open-sibling-detection predicate.
    SELECT COUNT(*) INTO v_session_nonfinalized_count
    FROM public.pos_orders
    WHERE table_session_id = v_session.id
      AND lower(COALESCE(status, '')) NOT IN ('cancelled', 'voided', 'rejected', 'closed', 'settled', 'picked up', 'delivered');

    IF v_session_nonfinalized_count > 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'ACTIVE_ORDER_EXISTS', 'message', 'A non-finalized order exists for the active session.');
    END IF;

    -- 10. ORPHAN PROOF -- CHECK 2 (ACTIVE ORDER POINTER): resolve active_order_id via the
    -- same canonical two-way identity match already used by secure_cancel_pos_order's and
    -- secure_release_pos_table's own ownership checks (numeric pos_orders.id OR
    -- offline_sync_id). table_id is deliberately NOT used as a matching criterion. If the
    -- pointer resolves to more than one distinct order, fail closed rather than pick one.
    SELECT
        COUNT(DISTINCT po.id),
        COUNT(DISTINCT po.id) FILTER (
            WHERE lower(COALESCE(po.status, '')) NOT IN ('cancelled', 'voided', 'rejected', 'closed', 'settled', 'picked up', 'delivered')
        )
    INTO v_pointer_match_count, v_pointer_nonfinalized_count
    FROM public.pos_orders po
    WHERE (v_table.active_order_id ~ '^\d+$' AND po.id = v_table.active_order_id::bigint)
       OR po.offline_sync_id = v_table.active_order_id;

    IF v_pointer_match_count > 1 THEN
        RETURN jsonb_build_object('success', false, 'error', 'POINTER_RESOLUTION_AMBIGUOUS', 'message', 'active_order_id resolves to more than one pos_orders row.');
    END IF;

    IF v_pointer_nonfinalized_count > 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'ACTIVE_ORDER_EXISTS', 'message', 'active_order_id resolves to a non-finalized order.');
    END IF;

    -- 11. RECOVERY MUTATION. By construction of steps 9-10 above, execution can only reach
    -- this point when ZERO non-finalized pos_orders were found -- so, structurally, this
    -- function contains no UPDATE/INSERT/DELETE against public.pos_orders anywhere, and
    -- none is reachable from this path either.
    UPDATE public.table_sessions
    SET status = 'closed',
        closed_at = NOW()
    WHERE id = v_session.id
      AND status <> 'closed';

    UPDATE public.pos_tables
    SET status = 'available',
        active_order_id = NULL,
        active_session_id = NULL
    WHERE id = p_table_id;

    -- 12. Audit Trail -- existing authoritative facility (system_audit_logs), same table
    -- secure_force_reset_table and secure_void_table_session already write to. No new
    -- audit table or column is introduced. validate_active_session_internal does not
    -- return a display name, so it is resolved via a minimal, read-only lookup against
    -- public.users; a NULL/missing name falls back to a non-fabricated placeholder rather
    -- than failing the audit insert.
    SELECT full_name INTO v_user_name FROM public.users WHERE id = v_auth.user_id;

    INSERT INTO public.system_audit_logs (
        user_name,
        user_role,
        action,
        details
    ) VALUES (
        COALESCE(v_user_name, 'User #' || v_auth.user_id::text),
        v_auth.role,
        'ORPHAN_TABLE_RECOVERED',
        jsonb_build_object(
            'table_id', p_table_id,
            'previous_active_order_id', v_prev_active_order_id,
            'previous_active_session_id', v_prev_active_session_id,
            'closed_table_session_id', v_session.id,
            'reason', v_reason,
            'timestamp', NOW()
        )
    );

    RETURN jsonb_build_object(
        'success', true,
        'already_recovered', false,
        'table_id', p_table_id,
        'closed_session_id', v_session.id
    );
END;
$$;

CREATE FUNCTION public.secure_start_table_session(
    p_session_token TEXT,
    p_table_id BIGINT,
    p_order_id TEXT,
    p_guests INTEGER DEFAULT 4,
    p_customer_name TEXT DEFAULT 'Walk-in Guest',
    p_customer_mobile TEXT DEFAULT 'Walk-in',
    p_client_session_token TEXT DEFAULT NULL,
    p_offline_sync_id TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
    v_auth RECORD;
    v_table RECORD;
    v_session RECORD;
    v_session_id BIGINT;
    v_session_token TEXT;
    v_active_sess_count INT := 0;
    -- Pass 2K/2L skeleton-order additions (not part of the live baseline):
    v_clean_offline_sync_id TEXT;
    v_skeleton_order_id BIGINT;
    v_order_number TEXT;
    v_live_order_count INTEGER;
    v_existing_skeleton RECORD;
BEGIN
    -- Basic parameter validation.
    IF p_session_token IS NULL OR TRIM(p_session_token) = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_TOKEN', 'message', 'Session token is required.');
    END IF;
    IF p_table_id IS NULL OR p_table_id <= 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_TABLE', 'message', 'Valid table ID is required.');
    END IF;
    IF p_order_id IS NULL OR TRIM(p_order_id) = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_ORDER', 'message', 'Order ID is required.');
    END IF;

    -- Authorization.
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF NOT v_auth.is_valid THEN
        RETURN jsonb_build_object('success', false, 'error', COALESCE(v_auth.error_code, 'INVALID_SESSION'), 'message', 'Session invalid or expired.');
    END IF;

    IF v_auth.role IS NULL OR lower(v_auth.role) NOT IN ('super_admin', 'admin', 'manager', 'pos_staff') THEN
        RETURN jsonb_build_object('success', false, 'error', 'UNAUTHORIZED_ROLE', 'message', 'Unauthorized role to start table session.');
    END IF;

    -- Table lookup + lock.
    SELECT * FROM public.pos_tables WHERE id = p_table_id FOR UPDATE INTO v_table;
    IF v_table.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'TABLE_NOT_FOUND', 'message', 'Target table does not exist.');
    END IF;

    IF v_table.status = 'occupied' THEN
        -- 1. Occupied by a different, non-blank order.
        IF v_table.active_order_id IS NOT NULL AND v_table.active_order_id <> '' AND v_table.active_order_id IS DISTINCT FROM p_order_id THEN
            RETURN jsonb_build_object('success', false, 'error', 'TABLE_OCCUPIED_CONFLICT');

        -- 2. Occupied with no recorded owner, but an active session pointer exists.
        ELSIF (v_table.active_order_id IS NULL OR v_table.active_order_id = '') AND v_table.active_session_id IS NOT NULL THEN
            RETURN jsonb_build_object('success', false, 'error', 'TABLE_ACTIVE_SESSION_CONFLICT');

        -- 3. Same owner -- idempotent retry path.
        ELSIF v_table.active_order_id = p_order_id THEN
            IF v_table.active_session_id IS NULL THEN
                RETURN jsonb_build_object('success', false, 'error', 'TABLE_SESSION_STATE_CONFLICT');
            END IF;

            SELECT * INTO v_session
            FROM public.table_sessions
            WHERE id = v_table.active_session_id
              AND table_id = p_table_id
              AND status = 'active'
            LIMIT 1;

            IF v_session.id IS NULL THEN
                RETURN jsonb_build_object('success', false, 'error', 'TABLE_SESSION_STATE_CONFLICT');
            END IF;

            -- PASS 2L-R1 Section 3 (required correction beyond the live
            -- baseline): a valid active table_session is no longer
            -- sufficient on its own to declare idempotent success. Exactly
            -- one durable, non-finalized pos_orders row bound to this
            -- table_id + table_session_id must also exist -- the post-
            -- skeleton invariant is "successful started table => exactly
            -- one durable server pos_order exists". Canonical finalized-
            -- status set copied verbatim from secure_cancel_pos_order /
            -- secure_recover_orphaned_pos_table.
            SELECT count(*) INTO v_live_order_count
            FROM public.pos_orders
            WHERE table_id = p_table_id
              AND table_session_id = v_session.id
              AND lower(COALESCE(status, '')) NOT IN ('cancelled', 'voided', 'rejected', 'closed', 'settled', 'picked up', 'delivered');

            IF v_live_order_count = 0 THEN
                RETURN jsonb_build_object('success', false, 'error', 'ORDER_STATE_CONFLICT');
            ELSIF v_live_order_count > 1 THEN
                RETURN jsonb_build_object('success', false, 'error', 'AMBIGUOUS_ORDER_STATE');
            END IF;

            SELECT * INTO v_existing_skeleton
            FROM public.pos_orders
            WHERE table_id = p_table_id
              AND table_session_id = v_session.id
              AND lower(COALESCE(status, '')) NOT IN ('cancelled', 'voided', 'rejected', 'closed', 'settled', 'picked up', 'delivered');

            v_clean_offline_sync_id := NULLIF(TRIM(p_offline_sync_id), '');
            -- Identity VERIFICATION only -- never claim/mutate identity
            -- during a start retry (explicit instruction: identity claiming
            -- belongs to secure_sync_pos_order alone). An incoming NULL
            -- never disturbs an existing genuine value.
            IF v_existing_skeleton.offline_sync_id IS NOT NULL
               AND v_clean_offline_sync_id IS NOT NULL
               AND v_existing_skeleton.offline_sync_id <> v_clean_offline_sync_id THEN
                RETURN jsonb_build_object('success', false, 'error', 'ORDER_IDENTITY_MISMATCH');
            END IF;

            RETURN jsonb_build_object(
                'success', true,
                'table_id', p_table_id,
                'table_session_id', v_session.id,
                'session_token', v_session.session_token,
                'active_order_id', p_order_id,
                'status', 'occupied',
                'order_id', v_existing_skeleton.id,
                'idempotent_retry', true
            );

        END IF;
        -- PASS 2L-R2: no ELSE here. The remaining combination (occupied,
        -- blank/null active_order_id, null active_session_id) matches none
        -- of CASE D/C/B above and is not itself a distinct live conflict
        -- code -- per the exact live behavior, control falls through this
        -- END IF and the outer one below, into the table_sessions count
        -- check and (if that passes) CASE A, exactly as it would for a
        -- non-occupied table. See file header for why this is intentional,
        -- not an oversight.
    END IF;

    -- Not occupied. Count check against table_sessions, combined with the
    -- table's own active_session_id pointer.
    SELECT COUNT(*) INTO v_active_sess_count
    FROM public.table_sessions
    WHERE table_id = p_table_id AND status = 'active';

    IF v_table.status = 'available'
       AND (v_table.active_session_id IS NOT NULL OR v_active_sess_count > 0) THEN
        RETURN jsonb_build_object('success', false, 'error', 'TABLE_SESSION_STATE_CONFLICT');
    END IF;

    -- CASE A: clean available table. Fresh-identity claim safety ahead of
    -- the skeleton INSERT's own unique index (Pass 2K addition -- defense-
    -- in-depth, not part of the live baseline).
    v_clean_offline_sync_id := NULLIF(TRIM(p_offline_sync_id), '');
    IF v_clean_offline_sync_id IS NOT NULL THEN
        IF EXISTS (
            SELECT 1 FROM public.pos_orders
            WHERE offline_sync_id = v_clean_offline_sync_id
              AND table_id IS DISTINCT FROM p_table_id
        ) THEN
            RETURN jsonb_build_object('success', false, 'error', 'ORDER_IDENTITY_MISMATCH');
        END IF;
    END IF;

    -- Exact live session-token fallback formula.
    v_session_token := COALESCE(
        NULLIF(TRIM(p_client_session_token), ''),
        'sess_' ||
        (extract(epoch from now())::bigint)::text ||
        '_' ||
        floor(random() * 1000000)::text
    );

    -- Exact live table_sessions INSERT.
    INSERT INTO public.table_sessions (
        table_id, session_token, customer_name, customer_mobile, status, payment_status
    ) VALUES (
        p_table_id, v_session_token, COALESCE(p_customer_name, 'Walk-in Guest'), COALESCE(p_customer_mobile, 'Walk-in'), 'active', 'pending'
    ) RETURNING id INTO v_session_id;

    -- PASS 2K/2L authorized addition #2: skeleton pos_orders row, inserted
    -- after table_sessions and before the pos_tables UPDATE. Column
    -- defaults match secure_sync_pos_order's own existing conventions;
    -- order_number reuses the identical shared_order_id_seq expression
    -- already in production (the double-sequence-consumption question is
    -- closed -- preserved as-is, not investigated).
    v_order_number := 'POS-' || nextval('public.shared_order_id_seq')::text;

    INSERT INTO public.pos_orders (
        status, payment_status, payment_method, order_source, delivery_mode,
        customer_name, phone, subtotal, gst, delivery_fee, total,
        table_id, table_session_id, offline_sync_id, order_number, created_at
    ) VALUES (
        'OPEN', 'Unpaid', 'Cash', 'pos_dinein', 'dinein',
        COALESCE(p_customer_name, 'Walk-in Guest'), COALESCE(p_customer_mobile, 'Walk-in'), 0, 0, 0, 0,
        p_table_id, v_session_id, v_clean_offline_sync_id, v_order_number, NOW()
    ) RETURNING id INTO v_skeleton_order_id;

    -- Exact live pos_tables UPDATE.
    UPDATE public.pos_tables SET
        status = 'occupied',
        guests = GREATEST(COALESCE(p_guests, 4), 1),
        active_order_id = p_order_id,
        active_session_id = v_session_id,
        updated_at = NOW()
    WHERE id = p_table_id;

    -- Exact live notification INSERT (v_table.name, no created_at column).
    INSERT INTO public.pos_table_notifications (
        table_id, table_number, session_id, type, status
    ) VALUES (
        p_table_id, COALESCE(v_table.name, ''), v_session_id, 'table_status_update', 'seen'
    );

    -- Exact live success payload, plus the authorized additive order_id field.
    RETURN jsonb_build_object(
        'success', true,
        'table_id', p_table_id,
        'table_session_id', v_session_id,
        'session_token', v_session_token,
        'active_order_id', p_order_id,
        'status', 'occupied',
        'order_id', v_skeleton_order_id
    );

-- Exact live exception behavior: a single top-level handler covering the
-- entire function body (no nested EXCEPTION anywhere in this file), so a
-- failure at any point -- including the new skeleton INSERT -- rolls back
-- every write performed above it (table_sessions INSERT, skeleton INSERT,
-- pos_tables UPDATE, notification INSERT) before this handler returns.
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'secure_start_table_session error: %', SQLERRM;
        RETURN jsonb_build_object(
            'success', false,
            'error', 'TRANSACTION_FAILED',
            'message', 'Failed to start table session due to internal database error.'
        );
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_report_kot_print_result(
    p_session_token TEXT,
    p_kot_event_id UUID,
    p_print_job_id UUID,
    p_outcome TEXT,
    p_attempt_type TEXT,
    p_error_message TEXT DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_kot RECORD;
    v_bounded_error TEXT;
    v_receipt_id BIGINT;
    v_inserted BOOLEAN := false;
BEGIN
    -- 1. Validate Session Token
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF NOT v_auth.is_valid THEN
        RETURN jsonb_build_object('success', false, 'error', v_auth.error_code);
    END IF;

    -- 2. Validate Authorization Roles (same canonical role set as the existing KOT RPCs)
    IF v_auth.role NOT IN ('admin', 'manager', 'pos_staff', 'super_admin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;

    -- 3. Validate Required Identifiers
    IF p_kot_event_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'MISSING_KOT_EVENT_ID');
    END IF;
    IF p_print_job_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'MISSING_PRINT_JOB_ID');
    END IF;

    -- 4. Validate Outcome & Attempt Type Enumerations (terminal outcomes only; no QUEUED/PRINTING)
    IF p_outcome IS NULL OR p_outcome NOT IN ('SUCCESS', 'FAILED') THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_OUTCOME');
    END IF;
    IF p_attempt_type IS NULL OR p_attempt_type NOT IN ('INITIAL', 'REPRINT') THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_ATTEMPT_TYPE');
    END IF;

    -- 5. Bound The Error Message Server-Side — never persist an unbounded string, a raw request
    --    dump, or a stack trace. A SUCCESS report never carries a stored error at all.
    v_bounded_error := CASE WHEN p_outcome = 'SUCCESS' THEN NULL ELSE LEFT(NULLIF(TRIM(p_error_message), ''), 500) END;

    -- 6. Resolve The KOT Strictly By kot_event_id And Lock Its Row For The Duration Of This Report.
    --    This row lock is what makes near-simultaneous reports for the same KOT (e.g. "Job A
    --    SUCCESS, Job B FAILED" arriving together) serialize safely: whichever call acquires the
    --    lock first fully completes its receipt insert + counter update before the second
    --    call's SELECT ... FOR UPDATE is allowed to proceed, so the aggregate counters below are
    --    never subject to a lost-update race. No client-supplied identity other than
    --    kot_event_id is trusted to resolve this row.
    SELECT * INTO v_kot FROM public.pos_kots WHERE kot_event_id = p_kot_event_id FOR UPDATE;
    IF v_kot.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'KOT_NOT_FOUND');
    END IF;

    -- 7. Idempotent Immutable Receipt Insert. This is the ONLY idempotency mechanism in this
    --    design (no scalar last_print_job_id column exists anywhere). A late network replay of
    --    an already-processed (kot_event_id, print_job_id) pair hits the UNIQUE constraint,
    --    inserts nothing, and v_receipt_id stays NULL.
    INSERT INTO public.pos_kot_print_reports (kot_event_id, print_job_id, outcome, attempt_type, error_message)
    VALUES (p_kot_event_id, p_print_job_id, p_outcome, p_attempt_type, v_bounded_error)
    ON CONFLICT (kot_event_id, print_job_id) DO NOTHING
    RETURNING id INTO v_receipt_id;

    v_inserted := (v_receipt_id IS NOT NULL);

    -- 8. Mutate The Aggregate Counters ONLY When A NEW Receipt Was Actually Inserted. A replay
    --    (v_inserted = false) falls through untouched and simply returns the current state.
    --    Note what this UPDATE never touches: kot_number, kot_type, order_id, offline_sync_id,
    --    table_id, table_session_id, any pos_kot_items row, or any logical KOT state — all of
    --    those remain the exclusive property of secure_save_kot_event and are frozen here.
    IF v_inserted THEN
        UPDATE public.pos_kots
        SET
            print_attempt_count = print_attempt_count + 1,
            last_print_attempt_at = NOW(),
            last_print_attempt_type = p_attempt_type,
            print_success_count = print_success_count + (CASE WHEN p_outcome = 'SUCCESS' THEN 1 ELSE 0 END),
            -- Sticky: first_printed_at is set once, on the first-ever SUCCESS, and never cleared
            -- or moved by any later attempt of any outcome.
            first_printed_at = CASE WHEN p_outcome = 'SUCCESS' THEN COALESCE(first_printed_at, NOW()) ELSE first_printed_at END,
            -- last_printed_at tracks the most recent SUCCESSFUL print specifically (distinct from
            -- last_print_attempt_at, which tracks the most recent attempt of ANY outcome).
            last_printed_at = CASE WHEN p_outcome = 'SUCCESS' THEN NOW() ELSE last_printed_at END,
            -- last_print_error reflects only the LATEST attempt's outcome and is cleared on a
            -- SUCCESS — it is not sticky, and is intentionally independent of print_success_count.
            last_print_error = CASE WHEN p_outcome = 'SUCCESS' THEN NULL ELSE v_bounded_error END
        WHERE kot_event_id = p_kot_event_id
        RETURNING * INTO v_kot;
    END IF;

    -- 9. Return The Current Post-Report Aggregate State Either Way (whether this call actually
    --    inserted a new receipt or was a no-op replay), including the derived physical status.
    RETURN jsonb_build_object(
        'success', true,
        'kot_event_id', v_kot.kot_event_id,
        'receipt_recorded', v_inserted,
        'print_attempt_count', v_kot.print_attempt_count,
        'print_success_count', v_kot.print_success_count,
        'first_printed_at', v_kot.first_printed_at,
        'last_printed_at', v_kot.last_printed_at,
        'last_print_attempt_at', v_kot.last_print_attempt_at,
        'last_print_attempt_type', v_kot.last_print_attempt_type,
        'last_print_error', v_kot.last_print_error,
        'physical_print_status', CASE
            WHEN v_kot.print_success_count > 0 THEN 'PRINTED'
            WHEN v_kot.print_attempt_count > 0 THEN 'FAILED'
            WHEN v_kot.print_tracking_available IS NOT TRUE THEN 'UNKNOWN'
            ELSE 'NOT_PRINTED'
        END
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_get_kot_print_state(
    p_session_token TEXT,
    p_kot_event_ids UUID[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_distinct_ids UUID[];
    v_states JSONB;
BEGIN
    -- 1. Validate Session Token
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF NOT v_auth.is_valid THEN
        RETURN jsonb_build_object('success', false, 'error', v_auth.error_code);
    END IF;

    -- 2. Validate Authorization Roles
    IF v_auth.role NOT IN ('admin', 'manager', 'pos_staff', 'super_admin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;

    -- 3. Reject Empty / Invalid Input — never allow a NULL/empty array to fall through into an
    --    unfiltered scan.
    IF p_kot_event_ids IS NULL OR array_length(p_kot_event_ids, 1) IS NULL OR array_length(p_kot_event_ids, 1) = 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'MISSING_KOT_EVENT_IDS');
    END IF;

    -- 4. De-duplicate and drop NULL elements before bounding.
    SELECT ARRAY_AGG(DISTINCT x) INTO v_distinct_ids FROM UNNEST(p_kot_event_ids) AS x WHERE x IS NOT NULL;
    IF v_distinct_ids IS NULL OR array_length(v_distinct_ids, 1) IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'MISSING_KOT_EVENT_IDS');
    END IF;

    -- 5. Bound Input Size — reject rather than silently truncate, so a caller never mistakes a
    --    truncated result for a complete one.
    IF array_length(v_distinct_ids, 1) > 100 THEN
        RETURN jsonb_build_object('success', false, 'error', 'TOO_MANY_KOT_EVENT_IDS');
    END IF;

    -- 6. Bounded Read — exactly the requested ids, nothing else. No order/table/item columns, no
    --    receipt-table access, no mutation of any kind.
    SELECT jsonb_agg(
        jsonb_build_object(
            'kot_event_id', k.kot_event_id,
            'print_attempt_count', k.print_attempt_count,
            'print_success_count', k.print_success_count,
            'first_printed_at', k.first_printed_at,
            'last_printed_at', k.last_printed_at,
            'last_print_attempt_at', k.last_print_attempt_at,
            'last_print_attempt_type', k.last_print_attempt_type,
            'last_print_error', k.last_print_error,
            'physical_print_status', CASE
                WHEN k.print_success_count > 0 THEN 'PRINTED'
                WHEN k.print_attempt_count > 0 THEN 'FAILED'
                WHEN k.print_tracking_available IS NOT TRUE THEN 'UNKNOWN'
                ELSE 'NOT_PRINTED'
            END
        )
    ) INTO v_states
    FROM public.pos_kots k
    WHERE k.kot_event_id = ANY(v_distinct_ids);

    RETURN jsonb_build_object(
        'success', true,
        'kot_print_states', COALESCE(v_states, '[]'::jsonb)
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_get_website_orders_admin(p_session_token TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_orders JSONB;
BEGIN
    -- 1. Validate staff session
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);

    IF NOT v_auth.is_valid THEN
        RETURN jsonb_build_object('success', false, 'error', v_auth.error_code);
    END IF;

    -- 2. Role gate
    IF lower(v_auth.role) NOT IN ('admin', 'manager', 'pos_staff', 'super_admin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;

    -- 3. Read: active orders unbounded by age (LIMIT 500 safety ceiling),
    --    terminal/history orders bounded by status-specific terminal timestamp.
    WITH eligible_orders AS (
        (
            -- ACTIVE / actionable statuses: must remain visible regardless of age.
            SELECT o.*
            FROM public.orders o
            WHERE o.status IN (
                    'Pending', 'PENDING', 'Accepted', 'ACCEPTED', 'Preparing', 'PREPARING',
                    'Ready', 'READY', 'Out For Delivery', 'OUT_FOR_DELIVERY',
                    'Ready for pickup', 'READY_FOR_PICKUP', 'CONFIRMED'
                  )
              AND o.delivery_mode IN ('delivery', 'pickup', 'schedule', 'now', 'dinein')
            ORDER BY o.created_at DESC
            LIMIT 500
        )
        UNION ALL
        (
            -- TERMINAL / history statuses: bounded to recent window using
            -- status-specific lifecycle completion timestamps with legacy created_at fallback.
            SELECT o.*
            FROM public.orders o
            WHERE o.status IN (
                    'Completed', 'COMPLETED', 'Closed', 'CLOSED',
                    'Cancelled', 'CANCELLED', 'Delivered', 'DELIVERED'
                  )
              AND o.delivery_mode IN ('delivery', 'pickup', 'schedule', 'now', 'dinein')
              AND (
                  (
                      upper(o.status) IN ('CANCELLED', 'CANCELED')
                      AND COALESCE(o.cancelled_at, o.created_at) >= (NOW() - INTERVAL '2 days')
                  )
                  OR
                  (
                      upper(o.status) = 'DELIVERED'
                      AND COALESCE(o.delivered_at, o.completed_at, o.created_at) >= (NOW() - INTERVAL '2 days')
                  )
                  OR
                  (
                      upper(o.status) IN ('COMPLETED', 'CLOSED')
                      AND COALESCE(o.completed_at, o.delivered_at, o.created_at) >= (NOW() - INTERVAL '2 days')
                  )
              )
            ORDER BY o.created_at DESC
            LIMIT 200
        )
    )
    SELECT jsonb_agg(
        jsonb_build_object(
            'id', eo.id,
            'customer_name', eo.customer_name,
            'phone', eo.phone,
            'address', eo.address,
            'delivery_mode', eo.delivery_mode,
            'status', eo.status,
            'subtotal', eo.subtotal,
            'gst', eo.gst,
            'delivery_fee', eo.delivery_fee,
            'total', eo.total,
            'payment_method', eo.payment_method,
            'payment_status', eo.payment_status,
            'payment_reference', eo.payment_reference,
            'razorpay_payment_id', eo.razorpay_payment_id,
            'razorpay_order_id', eo.razorpay_order_id,
            'created_at', eo.created_at,
            'accepted_at', eo.accepted_at,
            'ready_at', eo.ready_at,
            'completed_at', eo.completed_at,
            'delivered_at', eo.delivered_at,
            'cancelled_at', eo.cancelled_at,
            'cancel_reason', eo.cancel_reason,
            'coupon_code', eo.coupon_code,
            'coupon_discount', eo.coupon_discount,
            'coins_redeemed', eo.coins_redeemed,
            'items', eo.items,
            'order_items', COALESCE(oit.items_json, '[]'::jsonb)
        )
        ORDER BY eo.created_at DESC
    ) INTO v_orders
    FROM eligible_orders eo
    LEFT JOIN LATERAL (
        SELECT jsonb_agg(
            jsonb_build_object(
                'id', items.id,
                'product_id', items.product_id,
                'product_name', items.product_name,
                'variant_name', items.variant_name,
                'addons', items.addons,
                'quantity', items.quantity,
                'price', items.price
            )
        ) AS items_json
        FROM public.order_items items
        WHERE items.order_id = eo.id
    ) oit ON TRUE;

    RETURN jsonb_build_object(
        'success', true,
        'orders', COALESCE(v_orders, '[]'::jsonb)
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_manage_choice_group(
    p_session_token TEXT,
    p_action TEXT,
    p_payload JSONB
)
RETURNS JSONB AS $$
DECLARE
    v_auth RECORD;
    v_actor_name TEXT;
    v_action TEXT;
    v_group_id BIGINT;
    v_group_rec RECORD;
    v_name TEXT;
    v_description TEXT;
    v_status TEXT;
    v_product_ids BIGINT[];
    v_product_id BIGINT;
    v_dup_count INTEGER;
    v_distinct_count INTEGER;
    v_next_sort INTEGER;
    v_inserted JSONB;
    v_deleted JSONB;
    v_data JSONB;
    v_row RECORD;
    v_item JSONB;
    v_reorder_product_ids BIGINT[];
    v_reorder_sort_orders INTEGER[];
    v_reorder_is_defaults BOOLEAN[];
    v_existing_count INTEGER;
    i INTEGER;
BEGIN
    -----------------------------------------------------------------
    -- 1. Session validation (fail closed)
    -----------------------------------------------------------------
    SELECT * INTO v_auth
    FROM public.validate_active_session_internal(p_session_token, NULL);

    IF v_auth.is_valid IS NOT TRUE THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_SESSION',
            'error', COALESCE(v_auth.error_code, 'INVALID_SESSION')
        );
    END IF;

    -----------------------------------------------------------------
    -- 2. Role authorization: admin / super_admin only (route-gated
    --    surface per App.jsx RoleProtectedRoute allowedRoles for
    --    /cheesybites-admin/menu/choice-groups). Role is taken from the
    --    validated session record, never from p_payload.
    -----------------------------------------------------------------
    IF v_auth.role IS NULL OR lower(v_auth.role) NOT IN ('admin', 'super_admin') THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'PERMISSION_DENIED',
            'error', 'PERMISSION_DENIED'
        );
    END IF;

    -- Resolve a display name for audit/attribution fields server-side.
    -- Never trust any name/identity value supplied in p_payload.
    SELECT COALESCE(full_name, employee_code, v_auth.role, 'admin')
      INTO v_actor_name
      FROM public.users
     WHERE id = v_auth.user_id;
    v_actor_name := COALESCE(v_actor_name, v_auth.role, 'admin');

    -----------------------------------------------------------------
    -- 3. Static action allowlist
    -----------------------------------------------------------------
    v_action := UPPER(trim(COALESCE(p_action, '')));

    IF v_action NOT IN (
        'CREATE_GROUP', 'UPDATE_GROUP', 'ARCHIVE_GROUP',
        'ASSIGN_PRODUCTS', 'REMOVE_PRODUCTS', 'REORDER_PRODUCTS'
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_ACTION',
            'error', 'INVALID_ACTION'
        );
    END IF;

    IF p_payload IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'error', 'MISSING_PAYLOAD');
    END IF;

    -----------------------------------------------------------------
    -- 4. Action dispatch. Wrapped so any unexpected error rolls back
    --    cleanly to a controlled response instead of leaking a raw
    --    Postgres error. Statements that can raise a *specific*,
    --    expected constraint violation (unique name, duplicate
    --    assignment, missing product FK) get their own inner
    --    BEGIN/EXCEPTION so the response names the actual conflict;
    --    this outer block is the catch-all safety net.
    -----------------------------------------------------------------
    BEGIN
        -------------------------------------------------------------
        -- CREATE_GROUP  payload: { name, description?, status? }
        -------------------------------------------------------------
        IF v_action = 'CREATE_GROUP' THEN
            v_name := trim(COALESCE(p_payload->>'name', ''));
            IF v_name = '' THEN
                RETURN jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'error', 'NAME_REQUIRED');
            END IF;

            v_status := trim(COALESCE(p_payload->>'status', 'active'));
            IF v_status NOT IN ('active', 'inactive', 'archived') THEN
                RETURN jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'error', 'INVALID_STATUS');
            END IF;

            BEGIN
                INSERT INTO public.choice_groups (name, description, status, created_by, updated_by)
                VALUES (v_name, COALESCE(p_payload->>'description', ''), v_status, v_actor_name, v_actor_name)
                RETURNING to_jsonb(choice_groups) INTO v_data;
            EXCEPTION WHEN unique_violation THEN
                RETURN jsonb_build_object('success', false, 'code', 'DUPLICATE', 'error', 'GROUP_NAME_NOT_UNIQUE');
            END;

            INSERT INTO public.system_audit_logs (user_name, user_role, action, details)
            VALUES (v_actor_name, v_auth.role, 'choice_group_create',
                    jsonb_build_object('group_id', v_data->>'id', 'name', v_name));

            RETURN jsonb_build_object('success', true, 'code', 'SUCCESS', 'data', v_data);

        -------------------------------------------------------------
        -- UPDATE_GROUP  payload: { id, name?, description?, status? }
        -------------------------------------------------------------
        ELSIF v_action = 'UPDATE_GROUP' THEN
            IF jsonb_typeof(p_payload->'id') IS DISTINCT FROM 'number' THEN
                RETURN jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'error', 'GROUP_ID_REQUIRED');
            END IF;
            v_group_id := (p_payload->>'id')::BIGINT;

            SELECT * INTO v_group_rec FROM public.choice_groups WHERE id = v_group_id FOR UPDATE;
            IF v_group_rec.id IS NULL THEN
                RETURN jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'error', 'GROUP_NOT_FOUND');
            END IF;

            v_name := v_group_rec.name;
            IF p_payload ? 'name' THEN
                v_name := trim(COALESCE(p_payload->>'name', ''));
                IF v_name = '' THEN
                    RETURN jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'error', 'NAME_CANNOT_BE_EMPTY');
                END IF;
            END IF;

            v_status := v_group_rec.status;
            IF p_payload ? 'status' THEN
                v_status := trim(COALESCE(p_payload->>'status', ''));
                IF v_status NOT IN ('active', 'inactive', 'archived') THEN
                    RETURN jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'error', 'INVALID_STATUS');
                END IF;
            END IF;

            v_description := v_group_rec.description;
            IF p_payload ? 'description' THEN
                v_description := p_payload->>'description';
            END IF;

            BEGIN
                UPDATE public.choice_groups
                SET name = v_name,
                    description = v_description,
                    status = v_status,
                    updated_by = v_actor_name,
                    updated_at = NOW()
                WHERE id = v_group_id
                RETURNING to_jsonb(choice_groups) INTO v_data;
            EXCEPTION WHEN unique_violation THEN
                RETURN jsonb_build_object('success', false, 'code', 'DUPLICATE', 'error', 'GROUP_NAME_NOT_UNIQUE');
            END;

            INSERT INTO public.system_audit_logs (user_name, user_role, action, details)
            VALUES (v_actor_name, v_auth.role, 'choice_group_update', jsonb_build_object('group_id', v_group_id));

            RETURN jsonb_build_object('success', true, 'code', 'SUCCESS', 'data', v_data);

        -------------------------------------------------------------
        -- ARCHIVE_GROUP  payload: { id }
        -------------------------------------------------------------
        ELSIF v_action = 'ARCHIVE_GROUP' THEN
            IF jsonb_typeof(p_payload->'id') IS DISTINCT FROM 'number' THEN
                RETURN jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'error', 'GROUP_ID_REQUIRED');
            END IF;
            v_group_id := (p_payload->>'id')::BIGINT;

            SELECT * INTO v_group_rec FROM public.choice_groups WHERE id = v_group_id FOR UPDATE;
            IF v_group_rec.id IS NULL THEN
                RETURN jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'error', 'GROUP_NOT_FOUND');
            END IF;

            UPDATE public.choice_groups
            SET status = 'archived', updated_by = v_actor_name, updated_at = NOW()
            WHERE id = v_group_id
            RETURNING to_jsonb(choice_groups) INTO v_data;

            INSERT INTO public.system_audit_logs (user_name, user_role, action, details)
            VALUES (v_actor_name, v_auth.role, 'choice_group_archive', jsonb_build_object('group_id', v_group_id));

            RETURN jsonb_build_object('success', true, 'code', 'SUCCESS', 'data', v_data);

        -------------------------------------------------------------
        -- ASSIGN_PRODUCTS  payload: { group_id, product_ids: [...] }
        -------------------------------------------------------------
        ELSIF v_action = 'ASSIGN_PRODUCTS' THEN
            IF jsonb_typeof(p_payload->'group_id') IS DISTINCT FROM 'number' THEN
                RETURN jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'error', 'GROUP_ID_REQUIRED');
            END IF;
            v_group_id := (p_payload->>'group_id')::BIGINT;

            IF jsonb_typeof(p_payload->'product_ids') IS DISTINCT FROM 'array'
               OR jsonb_array_length(p_payload->'product_ids') = 0 THEN
                RETURN jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'error', 'PRODUCT_IDS_REQUIRED');
            END IF;

            v_product_ids := ARRAY[]::BIGINT[];
            FOR v_item IN SELECT * FROM jsonb_array_elements(p_payload->'product_ids') LOOP
                IF jsonb_typeof(v_item) <> 'number' THEN
                    RETURN jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'error', 'INVALID_PRODUCT_ID');
                END IF;
                v_product_ids := v_product_ids || (v_item::text)::BIGINT;
            END LOOP;

            SELECT COUNT(*), COUNT(DISTINCT x) INTO v_dup_count, v_distinct_count FROM unnest(v_product_ids) AS x;
            IF v_dup_count <> v_distinct_count THEN
                RETURN jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'error', 'DUPLICATE_PRODUCT_ID_IN_PAYLOAD');
            END IF;

            SELECT * INTO v_group_rec FROM public.choice_groups WHERE id = v_group_id FOR UPDATE;
            IF v_group_rec.id IS NULL THEN
                RETURN jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'error', 'GROUP_NOT_FOUND');
            END IF;

            SELECT COALESCE(MAX(sort_order) + 1, 0) INTO v_next_sort
            FROM public.choice_group_products
            WHERE choice_group_id = v_group_id;

            v_inserted := '[]'::jsonb;
            BEGIN
                FOREACH v_product_id IN ARRAY v_product_ids LOOP
                    INSERT INTO public.choice_group_products
                        (choice_group_id, product_id, is_default, sort_order, created_by, updated_by)
                    VALUES (v_group_id, v_product_id, FALSE, v_next_sort, v_actor_name, v_actor_name)
                    RETURNING to_jsonb(choice_group_products) INTO v_data;
                    v_inserted := v_inserted || jsonb_build_array(v_data);
                    v_next_sort := v_next_sort + 1;
                END LOOP;
            EXCEPTION
                WHEN unique_violation THEN
                    RETURN jsonb_build_object('success', false, 'code', 'DUPLICATE', 'error', 'PRODUCT_ALREADY_ASSIGNED_TO_GROUP');
                WHEN foreign_key_violation THEN
                    RETURN jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'error', 'PRODUCT_NOT_FOUND');
            END;

            INSERT INTO public.system_audit_logs (user_name, user_role, action, details)
            VALUES (v_actor_name, v_auth.role, 'choice_group_assign_products',
                    jsonb_build_object('group_id', v_group_id, 'product_ids', to_jsonb(v_product_ids)));

            RETURN jsonb_build_object('success', true, 'code', 'SUCCESS', 'data', v_inserted);

        -------------------------------------------------------------
        -- REMOVE_PRODUCTS  payload: { group_id, product_ids: [...] }
        -------------------------------------------------------------
        ELSIF v_action = 'REMOVE_PRODUCTS' THEN
            IF jsonb_typeof(p_payload->'group_id') IS DISTINCT FROM 'number' THEN
                RETURN jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'error', 'GROUP_ID_REQUIRED');
            END IF;
            v_group_id := (p_payload->>'group_id')::BIGINT;

            IF jsonb_typeof(p_payload->'product_ids') IS DISTINCT FROM 'array'
               OR jsonb_array_length(p_payload->'product_ids') = 0 THEN
                RETURN jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'error', 'PRODUCT_IDS_REQUIRED');
            END IF;

            v_product_ids := ARRAY[]::BIGINT[];
            FOR v_item IN SELECT * FROM jsonb_array_elements(p_payload->'product_ids') LOOP
                IF jsonb_typeof(v_item) <> 'number' THEN
                    RETURN jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'error', 'INVALID_PRODUCT_ID');
                END IF;
                v_product_ids := v_product_ids || (v_item::text)::BIGINT;
            END LOOP;

            SELECT * INTO v_group_rec FROM public.choice_groups WHERE id = v_group_id FOR UPDATE;
            IF v_group_rec.id IS NULL THEN
                RETURN jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'error', 'GROUP_NOT_FOUND');
            END IF;

            v_deleted := '[]'::jsonb;
            FOR v_row IN
                DELETE FROM public.choice_group_products
                WHERE choice_group_id = v_group_id AND product_id = ANY(v_product_ids)
                RETURNING *
            LOOP
                v_deleted := v_deleted || jsonb_build_array(to_jsonb(v_row));
            END LOOP;

            INSERT INTO public.system_audit_logs (user_name, user_role, action, details)
            VALUES (v_actor_name, v_auth.role, 'choice_group_remove_products',
                    jsonb_build_object('group_id', v_group_id, 'product_ids', to_jsonb(v_product_ids)));

            RETURN jsonb_build_object('success', true, 'code', 'SUCCESS', 'data', v_deleted);

        -------------------------------------------------------------
        -- REORDER_PRODUCTS  payload: { group_id, items: [{product_id, sort_order, is_default?}, ...] }
        -- Two-pass: validate + build arrays first (no writes), verify
        -- every product already belongs to the group (no writes), THEN
        -- apply updates -- so an early return never leaves a partial
        -- write behind (RETURN does not roll back a transaction; only
        -- an exception does).
        -------------------------------------------------------------
        ELSIF v_action = 'REORDER_PRODUCTS' THEN
            IF jsonb_typeof(p_payload->'group_id') IS DISTINCT FROM 'number' THEN
                RETURN jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'error', 'GROUP_ID_REQUIRED');
            END IF;
            v_group_id := (p_payload->>'group_id')::BIGINT;

            IF jsonb_typeof(p_payload->'items') IS DISTINCT FROM 'array'
               OR jsonb_array_length(p_payload->'items') = 0 THEN
                RETURN jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'error', 'ITEMS_REQUIRED');
            END IF;

            v_reorder_product_ids := ARRAY[]::BIGINT[];
            v_reorder_sort_orders := ARRAY[]::INTEGER[];
            v_reorder_is_defaults := ARRAY[]::BOOLEAN[];

            FOR v_item IN SELECT * FROM jsonb_array_elements(p_payload->'items') LOOP
                IF jsonb_typeof(v_item->'product_id') IS DISTINCT FROM 'number'
                   OR jsonb_typeof(v_item->'sort_order') IS DISTINCT FROM 'number' THEN
                    RETURN jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'error', 'INVALID_ITEM_SHAPE');
                END IF;
                v_reorder_product_ids := v_reorder_product_ids || (v_item->>'product_id')::BIGINT;
                v_reorder_sort_orders := v_reorder_sort_orders || (v_item->>'sort_order')::INTEGER;
                v_reorder_is_defaults := v_reorder_is_defaults || COALESCE((v_item->>'is_default')::BOOLEAN, FALSE);
            END LOOP;

            SELECT COUNT(*), COUNT(DISTINCT x) INTO v_dup_count, v_distinct_count
            FROM unnest(v_reorder_product_ids) AS x;
            IF v_dup_count <> v_distinct_count THEN
                RETURN jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'error', 'DUPLICATE_PRODUCT_ID_IN_PAYLOAD');
            END IF;

            SELECT * INTO v_group_rec FROM public.choice_groups WHERE id = v_group_id FOR UPDATE;
            IF v_group_rec.id IS NULL THEN
                RETURN jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'error', 'GROUP_NOT_FOUND');
            END IF;

            SELECT COUNT(*) INTO v_existing_count
            FROM public.choice_group_products
            WHERE choice_group_id = v_group_id AND product_id = ANY(v_reorder_product_ids);

            IF v_existing_count <> array_length(v_reorder_product_ids, 1) THEN
                RETURN jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'error', 'ONE_OR_MORE_PRODUCTS_NOT_IN_GROUP');
            END IF;

            FOR i IN 1 .. array_length(v_reorder_product_ids, 1) LOOP
                UPDATE public.choice_group_products
                SET sort_order = v_reorder_sort_orders[i],
                    is_default = v_reorder_is_defaults[i],
                    updated_by = v_actor_name,
                    updated_at = NOW()
                WHERE choice_group_id = v_group_id AND product_id = v_reorder_product_ids[i];
            END LOOP;

            INSERT INTO public.system_audit_logs (user_name, user_role, action, details)
            VALUES (v_actor_name, v_auth.role, 'choice_group_reorder_products',
                    jsonb_build_object('group_id', v_group_id, 'items_count', array_length(v_reorder_product_ids, 1)));

            RETURN jsonb_build_object('success', true, 'code', 'SUCCESS', 'group_id', v_group_id);
        END IF;

    EXCEPTION
        WHEN unique_violation THEN
            RETURN jsonb_build_object('success', false, 'code', 'DUPLICATE', 'error', 'DUPLICATE_VALUE');
        WHEN foreign_key_violation THEN
            RETURN jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'error', 'REFERENCED_ROW_NOT_FOUND');
        WHEN check_violation THEN
            RETURN jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'error', 'CONSTRAINT_VIOLATION');
        WHEN OTHERS THEN
            RETURN jsonb_build_object('success', false, 'code', 'INTERNAL_ERROR', 'error', SQLERRM);
    END;

    -- Should be unreachable (every allowlisted action returns above), but
    -- fail closed rather than falling through with an implicit NULL.
    RETURN jsonb_build_object('success', false, 'code', 'INTERNAL_ERROR', 'error', 'UNHANDLED_ACTION');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp;

CREATE OR REPLACE FUNCTION public.secure_manage_qr_table_config(
    p_session_token TEXT,
    p_action TEXT,
    p_table_ids BIGINT[],
    p_enabled BOOLEAN DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_action TEXT;
    v_ids BIGINT[];
    v_requested_count INTEGER;
    v_existing_count INTEGER;
    v_not_configured_count INTEGER;
    v_new_token TEXT;
    v_updated_count INTEGER := 0;
    v_id BIGINT;
BEGIN
    -----------------------------------------------------------------
    -- 1. Session validation (fail closed). Role and user_id come only
    --    from the validated session -- never trusted from the client.
    -----------------------------------------------------------------
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);

    IF v_auth.is_valid IS NOT TRUE THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_SESSION',
            'error', COALESCE(v_auth.error_code, 'INVALID_SESSION')
        );
    END IF;

    -----------------------------------------------------------------
    -- 2. Role authorization: admin / super_admin only, matching
    --    /cheesybites-admin/qr-table-management's own
    --    RoleProtectedRoute allowedRoles in App.jsx exactly.
    -----------------------------------------------------------------
    IF v_auth.role IS NULL OR lower(v_auth.role) NOT IN ('admin', 'super_admin') THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'PERMISSION_DENIED',
            'error', 'PERMISSION_DENIED'
        );
    END IF;

    -----------------------------------------------------------------
    -- 3. Static action allowlist
    -----------------------------------------------------------------
    v_action := UPPER(trim(COALESCE(p_action, '')));

    IF v_action NOT IN ('GENERATE', 'SET_ENABLED', 'REGENERATE') THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_ACTION', 'error', 'INVALID_ACTION');
    END IF;

    -----------------------------------------------------------------
    -- 4. Table id list validation. Dedupe defensively so an
    --    accidental duplicate id in the request can't make the
    --    existence-count check below miscompare.
    -----------------------------------------------------------------
    IF p_table_ids IS NULL OR array_length(p_table_ids, 1) IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'error', 'NO_TABLE_IDS');
    END IF;

    SELECT ARRAY(SELECT DISTINCT x FROM unnest(p_table_ids) AS x) INTO v_ids;
    v_requested_count := array_length(v_ids, 1);

    IF v_action = 'SET_ENABLED' AND p_enabled IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'error', 'ENABLED_FLAG_REQUIRED');
    END IF;

    -----------------------------------------------------------------
    -- 5. Validate the COMPLETE requested set exists BEFORE any
    --    mutation, so a bulk request containing one bad id rejects
    --    the whole batch instead of partially mutating it.
    -----------------------------------------------------------------
    SELECT COUNT(*) INTO v_existing_count FROM public.pos_tables WHERE id = ANY(v_ids);
    IF v_existing_count IS DISTINCT FROM v_requested_count THEN
        RETURN jsonb_build_object('success', false, 'code', 'TABLE_NOT_FOUND', 'error', 'ONE_OR_MORE_TABLES_NOT_FOUND');
    END IF;

    -- SET_ENABLED's pre-existing business rule (previously enforced only
    -- by the client hiding the toggle until a table had a qr_token):
    -- a table must already be QR-configured before it can be enabled or
    -- disabled.
    IF v_action = 'SET_ENABLED' THEN
        SELECT COUNT(*) INTO v_not_configured_count
        FROM public.pos_tables
        WHERE id = ANY(v_ids) AND qr_token IS NULL;

        IF v_not_configured_count > 0 THEN
            RETURN jsonb_build_object('success', false, 'code', 'QR_NOT_CONFIGURED', 'error', 'ONE_OR_MORE_TABLES_NOT_CONFIGURED');
        END IF;
    END IF;

    -----------------------------------------------------------------
    -- 6. Perform the mutation. Explicit allowlisted columns only.
    -----------------------------------------------------------------
    IF v_action = 'GENERATE' THEN
        -- Matches the original handleGenerateQR: always assigns a fresh
        -- token and force-enables QR ordering, regardless of prior state.
        FOR v_id IN SELECT unnest(v_ids) LOOP
            v_new_token := encode(extensions.gen_random_bytes(32), 'hex');
            UPDATE public.pos_tables
               SET qr_token = v_new_token,
                   qr_enabled = TRUE,
                   last_generated = NOW()
             WHERE id = v_id;
            v_updated_count := v_updated_count + 1;
        END LOOP;

    ELSIF v_action = 'REGENERATE' THEN
        -- Matches both original call sites:
        --  - single handleRegenerateToken: new token + last_generated,
        --    qr_enabled left UNTOUCHED (p_enabled passed as NULL).
        --  - handleBulkRegenerate: new token + last_generated, AND
        --    force qr_enabled = TRUE (p_enabled passed as TRUE).
        -- Whether qr_enabled is touched at all is controlled by whether
        -- the caller supplied p_enabled.
        FOR v_id IN SELECT unnest(v_ids) LOOP
            v_new_token := encode(extensions.gen_random_bytes(32), 'hex');
            IF p_enabled IS NOT NULL THEN
                UPDATE public.pos_tables
                   SET qr_token = v_new_token,
                       qr_enabled = p_enabled,
                       last_generated = NOW()
                 WHERE id = v_id;
            ELSE
                UPDATE public.pos_tables
                   SET qr_token = v_new_token,
                       last_generated = NOW()
                 WHERE id = v_id;
            END IF;
            v_updated_count := v_updated_count + 1;
        END LOOP;

    ELSIF v_action = 'SET_ENABLED' THEN
        UPDATE public.pos_tables
           SET qr_enabled = p_enabled
         WHERE id = ANY(v_ids);
        GET DIAGNOSTICS v_updated_count = ROW_COUNT;
    END IF;

    RETURN jsonb_build_object('success', true, 'action', v_action, 'updated_count', v_updated_count);
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_validate_qr_table_access(
    p_table_identifier TEXT,
    p_qr_token TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_identifier TEXT;
    v_token TEXT;
    v_match_count INTEGER;
    v_table RECORD;
BEGIN
    v_identifier := NULLIF(TRIM(COALESCE(p_table_identifier, '')), '');
    v_token := NULLIF(TRIM(COALESCE(p_qr_token, '')), '');

    -- Missing table identifier or missing token -> fail closed, generic
    -- error (never distinguish "missing" from "wrong").
    IF v_identifier IS NULL OR v_token IS NULL THEN
        RETURN jsonb_build_object('success', false, 'valid', false, 'error', 'INVALID_CREDENTIALS');
    END IF;

    -- Exact-one-row requirement (see migration header) -- fails closed on
    -- zero matches (unknown table / wrong token / disabled-and-cleared
    -- token) AND on more than one match (would only occur under a
    -- pathological duplicate name + duplicate token, which is not possible
    -- given qr_token's cryptographic generation, but this never trusts
    -- that assumption blindly).
    SELECT COUNT(*) INTO v_match_count
    FROM public.pos_tables
    WHERE name = v_identifier AND qr_token = v_token;

    IF v_match_count IS DISTINCT FROM 1 THEN
        RETURN jsonb_build_object('success', false, 'valid', false, 'error', 'INVALID_CREDENTIALS');
    END IF;

    SELECT id, table_number, name, capacity, status, qr_enabled
    INTO v_table
    FROM public.pos_tables
    WHERE name = v_identifier AND qr_token = v_token;

    IF v_table.qr_enabled IS NOT TRUE THEN
        RETURN jsonb_build_object('success', false, 'valid', false, 'error', 'INVALID_CREDENTIALS');
    END IF;

    -- Success payload: minimal safe metadata only. qr_token is never
    -- returned, and no other table's data is ever touched or revealed.
    RETURN jsonb_build_object(
        'success', true,
        'valid', true,
        'table', jsonb_build_object(
            'id', v_table.id,
            'table_number', v_table.table_number,
            'name', v_table.name,
            'capacity', v_table.capacity,
            'status', v_table.status
        )
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_start_qr_table_session(
    p_table_identifier TEXT,
    p_qr_token TEXT,
    p_customer_name TEXT,
    p_customer_mobile TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
    v_identifier TEXT;
    v_token TEXT;
    v_name TEXT;
    v_mobile TEXT;
    v_match_count INTEGER;
    v_table RECORD;
    v_existing_session RECORD;
    v_session_age_ms NUMERIC;
    v_stale_grace_ms CONSTANT NUMERIC := 20 * 60 * 1000;
    v_live_order_count INTEGER;
    v_session_token TEXT;
    v_session_id BIGINT;
    v_started_at TIMESTAMPTZ;
BEGIN
    v_identifier := NULLIF(TRIM(COALESCE(p_table_identifier, '')), '');
    v_token := NULLIF(TRIM(COALESCE(p_qr_token, '')), '');
    v_name := NULLIF(TRIM(COALESCE(p_customer_name, '')), '');
    v_mobile := NULLIF(TRIM(COALESCE(p_customer_mobile, '')), '');

    IF v_identifier IS NULL OR v_token IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_CREDENTIALS');
    END IF;

    IF v_name IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_INPUT', 'message', 'Name is required.');
    END IF;

    IF v_mobile IS NULL OR v_mobile !~ '^[0-9]{10}$' THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_INPUT', 'message', 'A valid 10-digit mobile number is required.');
    END IF;

    SELECT COUNT(*) INTO v_match_count
    FROM public.pos_tables
    WHERE name = v_identifier AND qr_token = v_token;

    IF v_match_count IS DISTINCT FROM 1 THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_CREDENTIALS');
    END IF;

    SELECT * INTO v_table
    FROM public.pos_tables
    WHERE name = v_identifier AND qr_token = v_token
    FOR UPDATE;

    IF v_table.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_CREDENTIALS');
    END IF;

    IF v_table.qr_enabled IS NOT TRUE THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_CREDENTIALS');
    END IF;

    IF v_table.active_session_id IS NOT NULL THEN
        SELECT id, status, started_at
        INTO v_existing_session
        FROM public.table_sessions
        WHERE id = v_table.active_session_id;

        IF v_existing_session.id IS NOT NULL AND v_existing_session.status = 'active' THEN
            v_session_age_ms := EXTRACT(EPOCH FROM (NOW() - COALESCE(v_existing_session.started_at, NOW()))) * 1000;

            IF v_session_age_ms <= v_stale_grace_ms THEN
                RETURN jsonb_build_object('success', false, 'error', 'TABLE_OCCUPIED');
            END IF;

            SELECT COUNT(*) INTO v_live_order_count
            FROM public.pos_orders
            WHERE (table_session_id = v_existing_session.id OR table_id = v_table.id)
              AND status NOT IN ('Closed', 'Voided', 'Refunded', 'Cancelled');

            IF v_live_order_count > 0 THEN
                RETURN jsonb_build_object('success', false, 'error', 'TABLE_OCCUPIED');
            END IF;

            UPDATE public.table_sessions
               SET status = 'closed', closed_at = NOW()
             WHERE id = v_existing_session.id;
        END IF;
    END IF;

    v_session_token := 'sess_' || encode(extensions.gen_random_bytes(16), 'hex');
    v_started_at := NOW();

    INSERT INTO public.table_sessions (
        table_id, session_token, customer_name, customer_mobile, status, payment_status, started_at
    ) VALUES (
        v_table.id, v_session_token, v_name, v_mobile, 'active', 'pending', v_started_at
    ) RETURNING id INTO v_session_id;

    UPDATE public.pos_tables
       SET active_session_id = v_session_id,
           status = 'occupied'
     WHERE id = v_table.id;

    RETURN jsonb_build_object(
        'success', true,
        'session', jsonb_build_object(
            'id', v_session_id,
            'table_id', v_table.id,
            'table_number', v_table.name,
            'session_token', v_session_token,
            'status', 'active',
            'started_at', v_started_at
        )
    );
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'secure_start_qr_table_session error: %', SQLERRM;
        RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED');
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_verify_qr_table_reentry(
    p_table_identifier TEXT,
    p_qr_token TEXT,
    p_customer_mobile TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_identifier TEXT;
    v_token TEXT;
    v_mobile TEXT;
    v_match_count INTEGER;
    v_table RECORD;
    v_session RECORD;
BEGIN
    v_identifier := NULLIF(TRIM(COALESCE(p_table_identifier, '')), '');
    v_token := NULLIF(TRIM(COALESCE(p_qr_token, '')), '');
    v_mobile := NULLIF(TRIM(COALESCE(p_customer_mobile, '')), '');

    IF v_identifier IS NULL OR v_token IS NULL OR v_mobile IS NULL THEN
        RETURN jsonb_build_object('success', false, 'verified', false, 'error', 'INVALID_CREDENTIALS');
    END IF;

    SELECT COUNT(*) INTO v_match_count
    FROM public.pos_tables
    WHERE name = v_identifier AND qr_token = v_token;

    IF v_match_count IS DISTINCT FROM 1 THEN
        RETURN jsonb_build_object('success', false, 'verified', false, 'error', 'INVALID_CREDENTIALS');
    END IF;

    SELECT id, active_session_id, qr_enabled
    INTO v_table
    FROM public.pos_tables
    WHERE name = v_identifier AND qr_token = v_token;

    IF v_table.qr_enabled IS NOT TRUE OR v_table.active_session_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'verified', false, 'error', 'NO_ACTIVE_SESSION');
    END IF;

    SELECT id, status, session_token, customer_mobile, customer_name, started_at
    INTO v_session
    FROM public.table_sessions
    WHERE id = v_table.active_session_id;

    IF v_session.id IS NULL OR v_session.status IS DISTINCT FROM 'active' THEN
        RETURN jsonb_build_object('success', false, 'verified', false, 'error', 'NO_ACTIVE_SESSION');
    END IF;

    IF v_session.customer_mobile IS NULL
       OR TRIM(v_session.customer_mobile) = ''
       OR v_session.customer_mobile = 'Walk-in' THEN
        RETURN jsonb_build_object('success', false, 'verified', false, 'error', 'SESSION_NOT_CLAIMED');
    END IF;

    IF v_session.customer_mobile IS DISTINCT FROM v_mobile THEN
        RETURN jsonb_build_object('success', false, 'verified', false, 'error', 'MOBILE_MISMATCH');
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'verified', true,
        'session', jsonb_build_object(
            'id', v_session.id,
            'table_id', v_table.id,
            'session_token', v_session.session_token,
            'status', v_session.status,
            'customer_name', v_session.customer_name,
            'started_at', v_session.started_at
        )
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_get_pos_qr_pending_admin(
    p_session_token TEXT,
    p_table_id BIGINT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_notifications JSONB;
    v_pending_orders JSONB;
    v_stale_table_ids BIGINT[];
    v_active_table_ids BIGINT[];
BEGIN
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF NOT v_auth.is_valid THEN
        RETURN jsonb_build_object('success', false, 'error', v_auth.error_code);
    END IF;

    IF v_auth.role NOT IN ('super_admin', 'admin', 'manager', 'pos_staff', 'kitchen_staff') THEN
        RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;

    -- Self-heal pass: only for the global (unfiltered) view.
    IF p_table_id IS NULL THEN
        -- Tables that currently have at least one still-pending 'new_order'
        -- notification AND a real waiting_confirmation order behind it.
        SELECT COALESCE(array_agg(DISTINCT o.table_id), '{}')
        INTO v_active_table_ids
        FROM public.pos_orders o
        WHERE o.status = 'waiting_confirmation'
          AND o.table_id IN (
              SELECT DISTINCT n.table_id
              FROM public.pos_table_notifications n
              WHERE n.type = 'new_order' AND n.status IN ('pending', 'displayed')
          );

        -- Any 'new_order' notification (pending/displayed) whose table is
        -- NOT in that active set has nothing left to accept -- self-heal to
        -- 'seen' so it stops resurfacing (mirrors fetchQrData's existing,
        -- currently-broken client-side attempt at the same fix).
        UPDATE public.pos_table_notifications
        SET status = 'seen'
        WHERE type = 'new_order'
          AND status IN ('pending', 'displayed')
          AND NOT (table_id = ANY(v_active_table_ids));

        -- Notifications genuinely backed by a pending order: promote
        -- 'pending' -> 'displayed' (matches TableManagement's own existing
        -- "mark as displayed once shown" bookkeeping).
        UPDATE public.pos_table_notifications
        SET status = 'displayed'
        WHERE type = 'new_order'
          AND status = 'pending'
          AND table_id = ANY(v_active_table_ids);
    END IF;

    -- Actionable notifications: service-type ones (bill/call/water/
    -- assistance) while still 'pending', plus 'new_order' ones while
    -- 'pending' or 'displayed' -- exactly POSNotificationWrapper's own
    -- fetchRequests() filter, reused verbatim server-side.
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id', n.id,
            'table_id', n.table_id,
            'table_number', n.table_number,
            'type', n.type,
            'status', n.status,
            'created_at', n.created_at
        ) ORDER BY n.created_at ASC
    ), '[]'::jsonb)
    INTO v_notifications
    FROM public.pos_table_notifications n
    WHERE (p_table_id IS NULL OR n.table_id = p_table_id)
      AND (
          (n.type IN ('bill_request', 'bill_requested', 'call_service', 'call_waiter', 'waiter', 'water_request', 'water', 'assistance_request', 'assistance') AND n.status = 'pending')
          OR (n.type = 'new_order' AND n.status IN ('pending', 'displayed'))
      );

    -- Pending QR orders (status = waiting_confirmation), with items, for the
    -- accept + KOT-print pipeline (acceptQrOrder / printQrOrderKOT in
    -- qrOrderAcceptService.js) -- full field set that pipeline actually
    -- reads, no more (no customer address beyond what it already writes to
    -- pos_orders itself, no unrelated financial columns).
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id', o.id,
            'table_id', o.table_id,
            'table_session_id', o.table_session_id,
            'customer_name', o.customer_name,
            'phone', o.phone,
            'address', o.address,
            'payment_method', o.payment_method,
            'payment_status', o.payment_status,
            'subtotal', o.subtotal,
            'gst', o.gst,
            'delivery_fee', o.delivery_fee,
            'total', o.total,
            'status', o.status,
            'notes', o.notes,
            'offline_sync_id', o.offline_sync_id,
            'business_date', o.business_date,
            'created_at', o.created_at,
            'pos_order_items', COALESCE((
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'id', it.id,
                        'order_id', it.order_id,
                        'product_id', it.product_id,
                        'product_name', it.product_name,
                        'variant_name', it.variant_name,
                        'addons', it.addons,
                        'quantity', it.quantity,
                        'price', it.price,
                        'total', it.total,
                        'status', it.status,
                        'rejection_reason', it.rejection_reason
                    ) ORDER BY it.id ASC
                )
                FROM public.pos_order_items it
                WHERE it.order_id = o.id
            ), '[]'::jsonb)
        ) ORDER BY o.id ASC
    ), '[]'::jsonb)
    INTO v_pending_orders
    FROM public.pos_orders o
    WHERE o.status = 'waiting_confirmation'
      AND (p_table_id IS NULL OR o.table_id = p_table_id);

    RETURN jsonb_build_object(
        'success', true,
        'notifications', v_notifications,
        'pending_qr_orders', v_pending_orders
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'error', 'server_error', 'message', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_get_customer_qr_order_status(
    p_table_session_id BIGINT DEFAULT NULL,
    p_offline_sync_id TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
    v_order_session_id BIGINT;
    v_resolved_session_id BIGINT;
    v_session RECORD;
    v_orders JSONB;
BEGIN
    IF p_table_session_id IS NULL AND (p_offline_sync_id IS NULL OR trim(p_offline_sync_id) = '') THEN
        RETURN jsonb_build_object('success', false, 'error', 'invalid_input', 'message', 'A table session or order reference is required.');
    END IF;

    IF p_offline_sync_id IS NOT NULL AND trim(p_offline_sync_id) <> '' THEN
        SELECT table_session_id INTO v_order_session_id
        FROM public.pos_orders
        WHERE offline_sync_id = p_offline_sync_id
        LIMIT 1;
    END IF;

    -- Fail closed on a genuine mismatch rather than silently preferring
    -- either value -- this can only happen if the two credentials the
    -- browser is holding disagree about which session placed this order,
    -- which is never expected in normal operation.
    IF p_table_session_id IS NOT NULL AND v_order_session_id IS NOT NULL
       AND p_table_session_id <> v_order_session_id THEN
        RETURN jsonb_build_object('success', false, 'error', 'session_mismatch');
    END IF;

    v_resolved_session_id := COALESCE(p_table_session_id, v_order_session_id);

    IF v_resolved_session_id IS NULL THEN
        -- Order not inserted yet (secure_submit_qr_table_order's background
        -- write can still be in flight when the browser's first poll
        -- lands -- TableCheckout.jsx navigates instantly, before that RPC
        -- resolves) and no session_id was available either. Not an error:
        -- the frontend keeps showing its optimistic state and polls again.
        RETURN jsonb_build_object('success', true, 'found', false);
    END IF;

    SELECT * INTO v_session
    FROM public.table_sessions
    WHERE id = v_resolved_session_id;

    IF v_session IS NULL THEN
        RETURN jsonb_build_object('success', true, 'found', false);
    END IF;

    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id', o.id,
            'status', o.status,
            'notes', o.notes,
            'subtotal', o.subtotal,
            'gst', o.gst,
            'total', o.total,
            'created_at', o.created_at,
            'rejection_reason', o.rejection_reason,
            'offline_sync_id', o.offline_sync_id,
            'business_date', o.business_date,
            'pos_order_items', COALESCE((
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'id', it.id,
                        'order_id', it.order_id,
                        'product_name', it.product_name,
                        'variant_name', it.variant_name,
                        'addons', it.addons,
                        -- Effective quantity: the latest ledger new_qty for
                        -- this line when it has been corrected, else the
                        -- item row as before.
                        'quantity', CASE WHEN kc.latest_new_qty IS NOT NULL
                                         THEN trim_scale(kc.latest_new_qty)
                                         ELSE it.quantity END,
                        'price', it.price,
                        -- Keep the row's own total when the mirror already
                        -- carries the effective quantity (preserves any
                        -- item-level discount); otherwise price x effective.
                        'total', CASE WHEN kc.latest_new_qty IS NULL THEN it.total
                                      WHEN it.quantity = kc.latest_new_qty THEN it.total
                                      ELSE round(COALESCE(it.price, 0) * kc.latest_new_qty, 2) END,
                        'status', it.status,
                        'rejection_reason', it.rejection_reason,
                        -- Customer-safe correction marker only. No reason,
                        -- cashier, correction ids or timestamps.
                        'was_corrected', (kc.latest_new_qty IS NOT NULL),
                        'original_quantity', CASE WHEN kc.latest_new_qty IS NOT NULL
                                                  THEN trim_scale(kc.first_old_qty)
                                                  ELSE NULL END
                    ) ORDER BY it.id ASC
                )
                FROM public.pos_order_items it
                LEFT JOIN LATERAL (
                    SELECT (array_agg(c.new_qty ORDER BY c.id DESC))[1] AS latest_new_qty,
                           (array_agg(c.old_qty ORDER BY c.id ASC))[1]  AS first_old_qty
                    FROM public.kot_corrections c
                    WHERE c.order_id = it.order_id
                      AND it.session_item_id IS NOT NULL
                      AND c.line_id = it.session_item_id::text
                ) kc ON TRUE
                WHERE it.order_id = o.id
            ), '[]'::jsonb)
        ) ORDER BY o.id ASC
    ), '[]'::jsonb)
    INTO v_orders
    FROM public.pos_orders o
    WHERE o.table_session_id = v_resolved_session_id;

    RETURN jsonb_build_object(
        'success', true,
        'found', true,
        'session', jsonb_build_object(
            'id', v_session.id,
            'table_id', v_session.table_id,
            'status', v_session.status,
            'bill_request_status', v_session.bill_request_status,
            'request_expires_at', v_session.request_expires_at,
            'bill_status', v_session.bill_status,
            'billing_started_at', v_session.billing_started_at,
            'cashier_acknowledged', v_session.cashier_acknowledged,
            'started_at', v_session.started_at,
            'closed_at', v_session.closed_at
        ),
        'orders', v_orders
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'error', 'server_error', 'message', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_get_qr_guest_name(
    p_table_identifier TEXT,
    p_qr_token TEXT,
    p_customer_mobile TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_validation JSONB;
    v_phone TEXT;
    v_name TEXT;
    v_placeholders CONSTANT TEXT[] := ARRAY[
        'walk-in', 'walk in', 'walkin', 'walk-in guest', 'walk-in customer',
        'pos customer', 'guest', 'customer', 'unknown'
    ];
BEGIN
    -- 1. QR credential FIRST (exact reuse of the existing validator).
    v_validation := public.secure_validate_qr_table_access(p_table_identifier, p_qr_token);
    IF v_validation IS NULL OR COALESCE((v_validation->>'valid')::BOOLEAN, FALSE) IS NOT TRUE THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_CREDENTIALS');
    END IF;

    -- 2. Normalize to exactly 10 digits.
    v_phone := REGEXP_REPLACE(COALESCE(p_customer_mobile, ''), '\D', '', 'g');
    IF LENGTH(v_phone) = 12 AND LEFT(v_phone, 2) = '91' THEN
        v_phone := SUBSTRING(v_phone FROM 3);
    ELSIF LENGTH(v_phone) = 11 AND LEFT(v_phone, 1) = '0' THEN
        v_phone := SUBSTRING(v_phone FROM 2);
    END IF;

    IF v_phone !~ '^[6-9][0-9]{9}$' THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_PHONE');
    END IF;

    -- 3a. CRM record (exact match).
    SELECT TRIM(c.name) INTO v_name
    FROM public.customers c
    WHERE c.mobile = v_phone
      AND NULLIF(TRIM(COALESCE(c.name, '')), '') IS NOT NULL
      AND LOWER(TRIM(c.name)) <> ALL (v_placeholders)
    ORDER BY c.id ASC
    LIMIT 1;

    -- 3b. Registered account fallback (exact match).
    IF v_name IS NULL THEN
        SELECT COALESCE(NULLIF(TRIM(u.name), ''), NULLIF(TRIM(u.full_name), '')) INTO v_name
        FROM public.users u
        WHERE (u.mobile = v_phone OR u.phone = v_phone)
          AND COALESCE(NULLIF(TRIM(u.name), ''), NULLIF(TRIM(u.full_name), '')) IS NOT NULL
          AND LOWER(COALESCE(NULLIF(TRIM(u.name), ''), NULLIF(TRIM(u.full_name), ''))) <> ALL (v_placeholders)
        ORDER BY u.id ASC
        LIMIT 1;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'found', v_name IS NOT NULL,
        'display_name', v_name
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'error', 'server_error');
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_submit_customer_table_request(
    p_table_id BIGINT,
    p_table_session_id BIGINT DEFAULT NULL,
    p_session_token TEXT DEFAULT NULL,
    p_request_type TEXT DEFAULT NULL,
    p_notes TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
    v_session RECORD;
    v_table_number TEXT;
    v_clean_type TEXT;
    v_family TEXT;
    v_existing_id BIGINT;
    v_ack_at TIMESTAMPTZ;
    v_cooldown_rem INTEGER;
    v_inserted_notif_id BIGINT;
    v_now_iso TIMESTAMPTZ;
    v_expires_iso TIMESTAMPTZ;
BEGIN
    -- 1. Validate mandatory inputs
    IF p_table_id IS NULL OR p_table_session_id IS NULL OR p_session_token IS NULL OR TRIM(p_session_token) = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_INPUT', 'message', 'Table ID, session ID, and session token are required.');
    END IF;

    -- 2. Lock and fetch table_sessions row for update (Serializes concurrent requests for session)
    SELECT id, table_id, status, session_token INTO v_session
    FROM public.table_sessions
    WHERE id = p_table_session_id
      AND table_id = p_table_id
      AND session_token = p_session_token
      AND status = 'active'
    LIMIT 1
    FOR UPDATE;

    IF v_session.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'STALE_SESSION_MISMATCH', 'message', 'Active table session not found or token authorization failed.');
    END IF;

    -- 3. Server-Side Request Type Allowlist
    v_clean_type := LOWER(TRIM(COALESCE(p_request_type, '')));
    IF v_clean_type NOT IN (
        'bill_request', 'bill_requested',
        'water', 'water_request',
        'tissue', 'tissue_request',
        'waiter', 'call_waiter',
        'assistance', 'assistance_request', 'call_service'
    ) THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_REQUEST_TYPE', 'message', 'Unsupported table service request type.');
    END IF;

    -- Normalize request type aliases
    IF v_clean_type = 'bill_requested' THEN v_clean_type := 'bill_request';
    ELSIF v_clean_type = 'water_request' THEN v_clean_type := 'water';
    ELSIF v_clean_type = 'tissue_request' THEN v_clean_type := 'tissue';
    ELSIF v_clean_type IN ('call_waiter', 'assistance_request', 'call_service', 'waiter') THEN v_clean_type := 'assistance';
    END IF;

    -- 4. Server-Side Cooldown and Duplicate Validation for Repeatable Services
    IF v_clean_type IN ('water', 'tissue', 'assistance') THEN
        v_family := v_clean_type;

        -- A. Pending / Displayed check across alias family
        SELECT id INTO v_existing_id
          FROM public.pos_table_notifications
         WHERE session_id = v_session.id
           AND status IN ('pending', 'displayed')
           AND (
               (v_family = 'water' AND type IN ('water', 'water_request')) OR
               (v_family = 'tissue' AND type IN ('tissue', 'tissue_request')) OR
               (v_family = 'assistance' AND type IN ('assistance', 'assistance_request', 'call_waiter', 'waiter', 'call_service'))
           )
         LIMIT 1;

        IF v_existing_id IS NOT NULL THEN
            RETURN jsonb_build_object(
                'success', false,
                'error', 'REQUEST_ALREADY_PENDING',
                'message', 'Request is already pending POS acknowledgement.'
            );
        END IF;

        -- B. 120-second Post-Acknowledgement Cooldown Check
        SELECT acknowledged_at INTO v_ack_at
          FROM public.pos_table_notifications
         WHERE session_id = v_session.id
           AND status IN ('acknowledged', 'seen')
           AND acknowledged_at IS NOT NULL
           AND (
               (v_family = 'water' AND type IN ('water', 'water_request')) OR
               (v_family = 'tissue' AND type IN ('tissue', 'tissue_request')) OR
               (v_family = 'assistance' AND type IN ('assistance', 'assistance_request', 'call_waiter', 'waiter', 'call_service'))
           )
         ORDER BY acknowledged_at DESC
         LIMIT 1;

        IF v_ack_at IS NOT NULL AND v_ack_at > (NOW() - INTERVAL '2 minutes') THEN
            v_cooldown_rem := GREATEST(0, CEIL(EXTRACT(EPOCH FROM ((v_ack_at + INTERVAL '2 minutes') - NOW())))::INTEGER);
            RETURN jsonb_build_object(
                'success', false,
                'error', 'COOLDOWN_ACTIVE',
                'cooldown_remaining_seconds', v_cooldown_rem,
                'message', 'Please wait before requesting this service again.'
            );
        END IF;
    END IF;

    -- 5. Fetch Table Number
    SELECT COALESCE(name, table_number, id::text) INTO v_table_number
    FROM public.pos_tables
    WHERE id = p_table_id;
    
    IF v_table_number IS NULL OR TRIM(v_table_number) = '' THEN
        v_table_number := p_table_id::text;
    END IF;

    -- 6. Insert New Notification Row
    INSERT INTO public.pos_table_notifications (
        table_id,
        table_number,
        session_id,
        type,
        status,
        created_at
    ) VALUES (
        v_session.table_id,
        v_table_number,
        v_session.id,
        v_clean_type,
        'pending',
        NOW()
    ) RETURNING id INTO v_inserted_notif_id;

    -- 7. Atomic Bill Request Session State Update (Macro status remains 'active')
    IF v_clean_type = 'bill_request' THEN
        v_now_iso := NOW();
        v_expires_iso := NOW() + INTERVAL '2 minutes';

        UPDATE public.table_sessions SET
            bill_request_status = 'waiting',
            request_created_at = v_now_iso,
            request_expires_at = v_expires_iso,
            cashier_acknowledged = false
        WHERE id = v_session.id;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'notification_id', v_inserted_notif_id,
        'table_id', v_session.table_id,
        'table_session_id', v_session.id,
        'type', v_clean_type,
        'status', 'pending'
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_update_pos_notification_status(
    p_session_token TEXT,
    p_notification_id BIGINT DEFAULT NULL,
    p_status TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_clean_status TEXT;
    v_notif RECORD;
    v_active_session_id BIGINT;
BEGIN
    -- 1. Validate mandatory session token
    IF p_session_token IS NULL OR TRIM(p_session_token) = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'MISSING_SESSION_TOKEN', 'message', 'Session token is required.');
    END IF;

    -- 2. POS session authentication
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF NOT v_auth.is_valid THEN
        RETURN jsonb_build_object('success', false, 'error', COALESCE(v_auth.error_code, 'UNAUTHORIZED'));
    END IF;

    IF v_auth.role NOT IN ('super_admin', 'admin', 'manager', 'pos_staff', 'kitchen_staff') THEN
        RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED', 'message', 'Insufficient permissions.');
    END IF;

    -- 3. Require mandatory p_notification_id (No bulk mutation path)
    IF p_notification_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_NOTIFICATION_ID', 'message', 'Notification ID is required.');
    END IF;

    -- 4. Lookup target notification row
    SELECT * INTO v_notif
      FROM public.pos_table_notifications
     WHERE id = p_notification_id;

    IF v_notif.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'NOTIFICATION_NOT_FOUND', 'message', 'Notification row not found.');
    END IF;

    -- 5. Type Allowlist Check (Reject new_order to prevent KOT workflow bypass)
    IF LOWER(TRIM(COALESCE(v_notif.type, ''))) NOT IN (
        'bill_request', 'bill_requested',
        'water_request', 'water',
        'call_waiter', 'waiter',
        'call_service', 'tissue',
        'assistance_request', 'assistance'
    ) THEN
        RETURN jsonb_build_object('success', false, 'error', 'UNSUPPORTED_NOTIFICATION_TYPE', 'message', 'This RPC only mutates customer service/bill requests.');
    END IF;

    -- 6. Validate target status allowlist ('acknowledged', 'seen')
    v_clean_status := LOWER(TRIM(COALESCE(p_status, '')));
    IF v_clean_status NOT IN ('acknowledged', 'seen') THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATUS', 'message', 'Invalid notification status.');
    END IF;

    -- 7. Validate Transition Matrix (Current status must be 'pending' or 'displayed')
    IF LOWER(TRIM(COALESCE(v_notif.status, ''))) NOT IN ('pending', 'displayed') THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATUS_TRANSITION', 'message', 'Notification transition is not allowed from current status.');
    END IF;

    -- 8. Single notification status mutation (Set acknowledged_at ONLY when status = 'acknowledged')
    UPDATE public.pos_table_notifications
       SET status = v_clean_status,
           acknowledged_at = CASE
               WHEN v_clean_status = 'acknowledged' THEN COALESCE(acknowledged_at, NOW())
               ELSE acknowledged_at
           END
     WHERE id = p_notification_id;

    -- 9. Atomic cashier_acknowledged & bill_request_status update for bill_request
    IF LOWER(TRIM(COALESCE(v_notif.type, ''))) IN ('bill_request', 'bill_requested') AND v_clean_status IN ('acknowledged', 'seen') THEN
        SELECT active_session_id INTO v_active_session_id
          FROM public.pos_tables
         WHERE id = v_notif.table_id;

        IF v_active_session_id IS NOT NULL THEN
            UPDATE public.table_sessions
               SET cashier_acknowledged = true,
                   bill_request_status = 'in_progress'
             WHERE id = v_active_session_id;
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'notification_id', p_notification_id,
        'status', v_clean_status,
        'updated_count', 1
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_get_customer_table_requests(
    p_table_id BIGINT,
    p_table_session_id BIGINT,
    p_session_token TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
    v_session_id BIGINT;

    v_water_raw_status TEXT := NULL;
    v_water_ack_at TIMESTAMPTZ := NULL;
    v_water_status TEXT := 'idle';
    v_water_pending BOOLEAN := false;
    v_water_cooldown INTEGER := 0;

    v_tissue_raw_status TEXT := NULL;
    v_tissue_ack_at TIMESTAMPTZ := NULL;
    v_tissue_status TEXT := 'idle';
    v_tissue_pending BOOLEAN := false;
    v_tissue_cooldown INTEGER := 0;

    v_assistance_raw_status TEXT := NULL;
    v_assistance_ack_at TIMESTAMPTZ := NULL;
    v_assistance_status TEXT := 'idle';
    v_assistance_pending BOOLEAN := false;
    v_assistance_cooldown INTEGER := 0;
BEGIN
    -- 1. Mandatory Input & Token Validation
    IF p_table_id IS NULL OR p_table_session_id IS NULL OR p_session_token IS NULL OR TRIM(p_session_token) = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_INPUT', 'message', 'Session parameters are required.');
    END IF;

    SELECT id INTO v_session_id
      FROM public.table_sessions
     WHERE id = p_table_session_id
       AND table_id = p_table_id
       AND session_token = p_session_token
       AND status = 'active'
     LIMIT 1;

    IF v_session_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'UNAUTHORIZED', 'message', 'Active session authorization failed.');
    END IF;

    -- 2. Water Family State Lookup
    SELECT LOWER(TRIM(status)), acknowledged_at
      INTO v_water_raw_status, v_water_ack_at
      FROM public.pos_table_notifications
     WHERE session_id = v_session_id
       AND type IN ('water', 'water_request')
     ORDER BY id DESC
     LIMIT 1;

    IF v_water_raw_status IS NOT NULL THEN
        v_water_status := v_water_raw_status;
        IF v_water_status IN ('pending', 'displayed') THEN
            v_water_pending := true;
        ELSIF v_water_status IN ('acknowledged', 'seen') THEN
            v_water_pending := false;
            IF v_water_ack_at IS NOT NULL AND v_water_ack_at > (NOW() - INTERVAL '2 minutes') THEN
                v_water_cooldown := GREATEST(0, CEIL(EXTRACT(EPOCH FROM ((v_water_ack_at + INTERVAL '2 minutes') - NOW())))::INTEGER);
            END IF;
        END IF;
    END IF;

    -- 3. Tissue Family State Lookup
    SELECT LOWER(TRIM(status)), acknowledged_at
      INTO v_tissue_raw_status, v_tissue_ack_at
      FROM public.pos_table_notifications
     WHERE session_id = v_session_id
       AND type IN ('tissue', 'tissue_request')
     ORDER BY id DESC
     LIMIT 1;

    IF v_tissue_raw_status IS NOT NULL THEN
        v_tissue_status := v_tissue_raw_status;
        IF v_tissue_status IN ('pending', 'displayed') THEN
            v_tissue_pending := true;
        ELSIF v_tissue_status IN ('acknowledged', 'seen') THEN
            v_tissue_pending := false;
            IF v_tissue_ack_at IS NOT NULL AND v_tissue_ack_at > (NOW() - INTERVAL '2 minutes') THEN
                v_tissue_cooldown := GREATEST(0, CEIL(EXTRACT(EPOCH FROM ((v_tissue_ack_at + INTERVAL '2 minutes') - NOW())))::INTEGER);
            END IF;
        END IF;
    END IF;

    -- 4. Assistance Family State Lookup
    SELECT LOWER(TRIM(status)), acknowledged_at
      INTO v_assistance_raw_status, v_assistance_ack_at
      FROM public.pos_table_notifications
     WHERE session_id = v_session_id
       AND type IN ('assistance', 'assistance_request', 'call_waiter', 'waiter', 'call_service')
     ORDER BY id DESC
     LIMIT 1;

    IF v_assistance_raw_status IS NOT NULL THEN
        v_assistance_status := v_assistance_raw_status;
        IF v_assistance_status IN ('pending', 'displayed') THEN
            v_assistance_pending := true;
        ELSIF v_assistance_status IN ('acknowledged', 'seen') THEN
            v_assistance_pending := false;
            IF v_assistance_ack_at IS NOT NULL AND v_assistance_ack_at > (NOW() - INTERVAL '2 minutes') THEN
                v_assistance_cooldown := GREATEST(0, CEIL(EXTRACT(EPOCH FROM ((v_assistance_ack_at + INTERVAL '2 minutes') - NOW())))::INTEGER);
            END IF;
        END IF;
    END IF;

    -- 5. Build JSON Result
    RETURN jsonb_build_object(
        'success', true,
        'table_id', p_table_id,
        'table_session_id', p_table_session_id,
        'services', jsonb_build_object(
            'water', jsonb_build_object(
                'status', v_water_status,
                'is_pending', v_water_pending,
                'cooldown_remaining_seconds', v_water_cooldown
            ),
            'tissue', jsonb_build_object(
                'status', v_tissue_status,
                'is_pending', v_tissue_pending,
                'cooldown_remaining_seconds', v_tissue_cooldown
            ),
            'assistance', jsonb_build_object(
                'status', v_assistance_status,
                'is_pending', v_assistance_pending,
                'cooldown_remaining_seconds', v_assistance_cooldown
            )
        )
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_manage_offer_admin(
    p_session_token TEXT,
    p_action TEXT,
    p_offer_id BIGINT DEFAULT NULL,
    p_offer_data JSONB DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_clean_action TEXT;
    v_inserted_id BIGINT;
    v_title TEXT;
    v_code TEXT;
    v_discount_type TEXT;
    v_discount_value NUMERIC;
    v_banner TEXT;
    v_min_order NUMERIC;
    v_expiry_date DATE;
    v_active BOOLEAN;
    v_max_discount NUMERIC;
    v_usage_limit BIGINT;
    v_user_usage_limit BIGINT;
    v_user_type TEXT;
    v_specific_users TEXT;
    v_available_channels JSONB;
    v_current_active BOOLEAN;
BEGIN
    -- 1. Validate session token
    IF p_session_token IS NULL OR TRIM(p_session_token) = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'UNAUTHORIZED', 'message', 'Session token is required.');
    END IF;

    -- 2. Authenticate admin session
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF NOT v_auth.is_valid THEN
        RETURN jsonb_build_object('success', false, 'error', COALESCE(v_auth.error_code, 'UNAUTHORIZED'));
    END IF;

    -- 3. Role Allowlist Check
    IF LOWER(TRIM(v_auth.role)) NOT IN ('super_admin', 'admin', 'manager') THEN
        RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED', 'message', 'Insufficient permissions for offer management.');
    END IF;

    -- 4. Action Allowlist
    v_clean_action := LOWER(TRIM(COALESCE(p_action, '')));
    IF v_clean_action NOT IN ('create', 'update', 'toggle', 'delete') THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_ACTION', 'message', 'Unsupported offer management action.');
    END IF;

    -- 5. Action Handlers
    IF v_clean_action = 'create' THEN
        IF p_offer_data IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error', 'INVALID_INPUT', 'message', 'Offer payload is required for create.');
        END IF;

        v_title := TRIM(p_offer_data->>'title');
        v_code := UPPER(TRIM(p_offer_data->>'code'));

        IF v_title IS NULL OR v_title = '' OR v_code IS NULL OR v_code = '' THEN
            RETURN jsonb_build_object('success', false, 'error', 'INVALID_INPUT', 'message', 'Title and coupon code are required.');
        END IF;

        -- Check duplicate code
        IF EXISTS (SELECT 1 FROM public.offers WHERE UPPER(code) = v_code) THEN
            RETURN jsonb_build_object('success', false, 'error', 'DUPLICATE_OFFER_CODE', 'message', 'An offer with this code already exists.');
        END IF;

        v_discount_type := LOWER(TRIM(COALESCE(p_offer_data->>'discount_type', 'percentage')));
        IF p_offer_data->>'discount_value' IS NOT NULL AND TRIM(p_offer_data->>'discount_value') != '' THEN
            v_discount_value := (p_offer_data->>'discount_value')::NUMERIC;
        ELSE
            v_discount_value := 0;
        END IF;

        v_banner := p_offer_data->>'banner';
        IF p_offer_data->>'min_order' IS NOT NULL AND TRIM(p_offer_data->>'min_order') != '' THEN
            v_min_order := (p_offer_data->>'min_order')::NUMERIC;
        ELSE
            v_min_order := NULL;
        END IF;

        -- Parse expiry_date safely
        IF p_offer_data->>'expiry_date' IS NOT NULL AND TRIM(p_offer_data->>'expiry_date') != '' THEN
            BEGIN
                v_expiry_date := (p_offer_data->>'expiry_date')::DATE;
            EXCEPTION WHEN OTHERS THEN
                RETURN jsonb_build_object('success', false, 'error', 'INVALID_EXPIRY_DATE', 'message', 'Expiry date must be a valid date in YYYY-MM-DD format.');
            END;
        ELSE
            v_expiry_date := NULL;
        END IF;

        v_active := COALESCE((p_offer_data->>'active')::BOOLEAN, true);

        IF p_offer_data->>'max_discount' IS NOT NULL AND TRIM(p_offer_data->>'max_discount') != '' THEN
            v_max_discount := (p_offer_data->>'max_discount')::NUMERIC;
        ELSE
            v_max_discount := NULL;
        END IF;

        IF p_offer_data->>'usage_limit' IS NOT NULL AND TRIM(p_offer_data->>'usage_limit') != '' THEN
            v_usage_limit := (p_offer_data->>'usage_limit')::BIGINT;
        ELSE
            v_usage_limit := NULL;
        END IF;

        IF p_offer_data->>'user_usage_limit' IS NOT NULL AND TRIM(p_offer_data->>'user_usage_limit') != '' THEN
            v_user_usage_limit := (p_offer_data->>'user_usage_limit')::BIGINT;
        ELSE
            v_user_usage_limit := NULL;
        END IF;

        v_user_type := COALESCE(p_offer_data->>'user_type', 'all');
        v_specific_users := p_offer_data->>'specific_users';
        v_available_channels := COALESCE(p_offer_data->'available_channels', '["website"]'::jsonb);

        INSERT INTO public.offers (
            title,
            code,
            discount_type,
            discount_value,
            banner,
            min_order,
            expiry_date,
            active,
            max_discount,
            usage_limit,
            user_usage_limit,
            user_type,
            specific_users,
            available_channels
        ) VALUES (
            v_title,
            v_code,
            v_discount_type,
            v_discount_value,
            v_banner,
            v_min_order,
            v_expiry_date,
            v_active,
            v_max_discount,
            v_usage_limit,
            v_user_usage_limit,
            v_user_type,
            v_specific_users,
            v_available_channels
        ) RETURNING id INTO v_inserted_id;

        RETURN jsonb_build_object(
            'success', true,
            'id', v_inserted_id,
            'action', 'create',
            'message', 'Offer created successfully.'
        );

    ELSIF v_clean_action = 'update' THEN
        IF p_offer_id IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error', 'INVALID_OFFER_ID', 'message', 'Offer ID is required for update.');
        END IF;

        IF p_offer_data IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error', 'INVALID_INPUT', 'message', 'Offer payload is required for update.');
        END IF;

        IF NOT EXISTS (SELECT 1 FROM public.offers WHERE id = p_offer_id) THEN
            RETURN jsonb_build_object('success', false, 'error', 'OFFER_NOT_FOUND', 'message', 'Target offer row not found.');
        END IF;

        -- Handle duplicate code check if code is being modified
        IF p_offer_data ? 'code' THEN
            v_code := UPPER(TRIM(p_offer_data->>'code'));
            IF EXISTS (SELECT 1 FROM public.offers WHERE UPPER(code) = v_code AND id != p_offer_id) THEN
                RETURN jsonb_build_object('success', false, 'error', 'DUPLICATE_OFFER_CODE', 'message', 'Another offer already uses this coupon code.');
            END IF;
        END IF;

        -- Safe expiry_date parsing for update patch
        IF p_offer_data ? 'expiry_date' THEN
            IF p_offer_data->>'expiry_date' IS NOT NULL AND TRIM(p_offer_data->>'expiry_date') != '' THEN
                BEGIN
                    v_expiry_date := (p_offer_data->>'expiry_date')::DATE;
                EXCEPTION WHEN OTHERS THEN
                    RETURN jsonb_build_object('success', false, 'error', 'INVALID_EXPIRY_DATE', 'message', 'Expiry date must be a valid date in YYYY-MM-DD format.');
                END;
            ELSE
                v_expiry_date := NULL;
            END IF;
        END IF;

        -- Explicit patch updates preserving unprovided fields
        UPDATE public.offers
           SET title = CASE WHEN p_offer_data ? 'title' THEN TRIM(p_offer_data->>'title') ELSE title END,
               code = CASE WHEN p_offer_data ? 'code' THEN UPPER(TRIM(p_offer_data->>'code')) ELSE code END,
               discount_type = CASE WHEN p_offer_data ? 'discount_type' THEN LOWER(TRIM(p_offer_data->>'discount_type')) ELSE discount_type END,
               discount_value = CASE 
                   WHEN p_offer_data ? 'discount_value' THEN 
                       (CASE WHEN p_offer_data->>'discount_value' IS NOT NULL AND TRIM(p_offer_data->>'discount_value') != '' THEN (p_offer_data->>'discount_value')::NUMERIC ELSE 0 END)
                   ELSE discount_value 
               END,
               banner = CASE WHEN p_offer_data ? 'banner' THEN p_offer_data->>'banner' ELSE banner END,
               min_order = CASE 
                   WHEN p_offer_data ? 'min_order' THEN 
                       (CASE WHEN p_offer_data->>'min_order' IS NOT NULL AND TRIM(p_offer_data->>'min_order') != '' THEN (p_offer_data->>'min_order')::NUMERIC ELSE NULL END)
                   ELSE min_order 
               END,
               expiry_date = CASE WHEN p_offer_data ? 'expiry_date' THEN v_expiry_date ELSE expiry_date END,
               active = CASE WHEN p_offer_data ? 'active' THEN (p_offer_data->>'active')::BOOLEAN ELSE active END,
               max_discount = CASE 
                   WHEN p_offer_data ? 'max_discount' THEN 
                       (CASE WHEN p_offer_data->>'max_discount' IS NOT NULL AND TRIM(p_offer_data->>'max_discount') != '' THEN (p_offer_data->>'max_discount')::NUMERIC ELSE NULL END)
                   ELSE max_discount 
               END,
               usage_limit = CASE 
                   WHEN p_offer_data ? 'usage_limit' THEN 
                       (CASE WHEN p_offer_data->>'usage_limit' IS NOT NULL AND TRIM(p_offer_data->>'usage_limit') != '' THEN (p_offer_data->>'usage_limit')::BIGINT ELSE NULL END)
                   ELSE usage_limit 
               END,
               user_usage_limit = CASE 
                   WHEN p_offer_data ? 'user_usage_limit' THEN 
                       (CASE WHEN p_offer_data->>'user_usage_limit' IS NOT NULL AND TRIM(p_offer_data->>'user_usage_limit') != '' THEN (p_offer_data->>'user_usage_limit')::BIGINT ELSE NULL END)
                   ELSE user_usage_limit 
               END,
               user_type = CASE WHEN p_offer_data ? 'user_type' THEN p_offer_data->>'user_type' ELSE user_type END,
               specific_users = CASE WHEN p_offer_data ? 'specific_users' THEN p_offer_data->>'specific_users' ELSE specific_users END,
               available_channels = CASE WHEN p_offer_data ? 'available_channels' THEN p_offer_data->'available_channels' ELSE available_channels END
         WHERE id = p_offer_id;

        RETURN jsonb_build_object(
            'success', true,
            'id', p_offer_id,
            'action', 'update',
            'message', 'Offer updated successfully.'
        );

    ELSIF v_clean_action = 'toggle' THEN
        IF p_offer_id IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error', 'INVALID_OFFER_ID', 'message', 'Offer ID is required for toggle.');
        END IF;

        SELECT active INTO v_current_active FROM public.offers WHERE id = p_offer_id;
        IF v_current_active IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error', 'OFFER_NOT_FOUND', 'message', 'Target offer row not found.');
        END IF;

        UPDATE public.offers
           SET active = NOT v_current_active
         WHERE id = p_offer_id;

        RETURN jsonb_build_object(
            'success', true,
            'id', p_offer_id,
            'action', 'toggle',
            'active', NOT v_current_active,
            'message', 'Offer status toggled successfully.'
        );

    ELSIF v_clean_action = 'delete' THEN
        IF p_offer_id IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error', 'INVALID_OFFER_ID', 'message', 'Offer ID is required for delete.');
        END IF;

        IF NOT EXISTS (SELECT 1 FROM public.offers WHERE id = p_offer_id) THEN
            RETURN jsonb_build_object('success', false, 'error', 'OFFER_NOT_FOUND', 'message', 'Target offer row not found.');
        END IF;

        DELETE FROM public.offers WHERE id = p_offer_id;

        RETURN jsonb_build_object(
            'success', true,
            'id', p_offer_id,
            'action', 'delete',
            'message', 'Offer deleted successfully.'
        );
    END IF;

    RETURN jsonb_build_object('success', false, 'error', 'UNEXPECTED_ERROR');
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_clear_pos_notification_history(
    p_session_token TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_cleared_count INTEGER := 0;
BEGIN
    -- 1. Validate mandatory session token
    IF p_session_token IS NULL OR TRIM(p_session_token) = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'MISSING_SESSION_TOKEN', 'message', 'Session token is required.');
    END IF;

    -- 2. POS session authentication
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF NOT v_auth.is_valid THEN
        RETURN jsonb_build_object('success', false, 'error', COALESCE(v_auth.error_code, 'UNAUTHORIZED'));
    END IF;

    IF v_auth.role NOT IN ('super_admin', 'admin', 'manager', 'pos_staff', 'kitchen_staff') THEN
        RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED', 'message', 'Insufficient permissions to clear notification history.');
    END IF;

    -- 3. Perform safe clear of terminal history rows only
    -- NEVER delete pending or displayed rows.
    -- NEVER delete service-family requests (water, tissue, assistance) acknowledged within last 120s to preserve customer cooldown.
    DELETE FROM public.pos_table_notifications
     WHERE status NOT IN ('pending', 'displayed')
       AND status IN ('seen', 'acknowledged', 'accepted', 'completed')
       AND NOT (
           LOWER(TRIM(COALESCE(type, ''))) IN ('water', 'water_request', 'tissue', 'tissue_request', 'call_service', 'assistance', 'assistance_request', 'call_waiter')
           AND acknowledged_at IS NOT NULL
           AND acknowledged_at > NOW() - INTERVAL '120 seconds'
       );

    GET DIAGNOSTICS v_cleared_count = ROW_COUNT;

    RETURN jsonb_build_object(
        'success', true,
        'cleared_count', v_cleared_count,
        'message', 'Notification history cleared successfully.'
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_get_pos_order_audit_history(
    p_session_token TEXT,
    p_order_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_order RECORD;
    v_table_name TEXT := NULL;
    v_closed_at TIMESTAMPTZ := NULL;
    v_events JSONB := '[]'::jsonb;
    
    r_kot RECORD;
    v_kot_items_text TEXT;
    v_kot_items_json JSONB;
    
    r_corr RECORD;
    r_notif RECORD;
BEGIN
    -- 1. Validate POS Staff Session
    IF p_session_token IS NULL OR TRIM(p_session_token) = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'MISSING_SESSION_TOKEN');
    END IF;

    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF NOT v_auth.is_valid THEN
        RETURN jsonb_build_object('success', false, 'error', v_auth.error_code);
    END IF;

    -- 2. Role Authorization Gate
    IF lower(v_auth.role) NOT IN ('admin', 'manager', 'cashier', 'staff', 'pos_staff', 'super_admin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;

    -- 3. Order ID Validation
    IF p_order_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_ORDER_ID');
    END IF;

    SELECT * INTO v_order FROM public.pos_orders WHERE id = p_order_id;
    IF v_order.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
    END IF;

    -- 4. Authoritative Table & Session Resolution
    IF v_order.table_id IS NOT NULL THEN
        SELECT COALESCE(name, id::text) INTO v_table_name
        FROM public.pos_tables
        WHERE id = v_order.table_id;
    ELSIF v_order.table_session_id IS NOT NULL THEN
        SELECT COALESCE(pt.name, pt.id::text) INTO v_table_name
        FROM public.table_sessions ts
        JOIN public.pos_tables pt ON pt.id = ts.table_id
        WHERE ts.id = v_order.table_session_id;
    END IF;

    IF v_order.table_session_id IS NOT NULL THEN
        SELECT closed_at INTO v_closed_at
        FROM public.table_sessions
        WHERE id = v_order.table_session_id;
    END IF;

    -- 5. EVENT 1: ORDER_CREATED (Factual creation event)
    DECLARE
        v_created_desc TEXT;
        v_mode_str TEXT;
        v_order_operator TEXT;
    BEGIN
        v_mode_str := lower(COALESCE(v_order.delivery_mode, 'dinein'));
        IF v_mode_str = 'dinein' THEN
            IF v_table_name IS NOT NULL AND TRIM(v_table_name) <> '' THEN
                v_created_desc := 'Order created for Table ' || v_table_name;
            ELSE
                v_created_desc := 'Order created for Dine-In Table';
            END IF;
        ELSIF v_mode_str = 'delivery' THEN
            v_created_desc := 'Order created for Delivery';
        ELSE
            v_created_desc := 'Order created for Takeaway';
        END IF;

        IF v_order.customer_name IS NOT NULL AND TRIM(v_order.customer_name) <> '' THEN
            v_created_desc := v_created_desc || '. Customer: ' || v_order.customer_name;
        ELSE
            v_created_desc := v_created_desc || '. Customer: Walk-in Guest';
        END IF;

        v_order_operator := COALESCE(NULLIF(TRIM(v_order.updated_by), ''), 'POS Operator');

        v_events := v_events || jsonb_build_array(jsonb_build_object(
            'event_type', 'ORDER_CREATED',
            'title', 'Order Initiated',
            'time', v_order.created_at,
            'formattedTime', to_char(v_order.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
            'cashier', v_order_operator,
            'details', v_created_desc,
            'metadata', jsonb_build_object(
                'order_id', v_order.id,
                'order_number', v_order.order_number,
                'delivery_mode', v_order.delivery_mode,
                'table_name', v_table_name,
                'customer_name', v_order.customer_name
            )
        ));
    END;

    -- 6. EVENT 2 & 3: KOT_GENERATED & KOT_PRINTED (Durable Server KOT Ledger)
    FOR r_kot IN (
        SELECT k.*
        FROM public.pos_kots k
        WHERE k.order_id = p_order_id
        ORDER BY k.id ASC
    ) LOOP
        -- Aggregate items for this KOT
        SELECT 
            string_agg(
                ki.product_name || ' (x' || ki.quantity::text || 
                CASE WHEN ki.variant IS NOT NULL AND TRIM(ki.variant) <> '' AND lower(ki.variant) <> 'regular' THEN ' - ' || ki.variant ELSE '' END || ')',
                ', '
            ),
            jsonb_agg(jsonb_build_object(
                'product_name', ki.product_name,
                'quantity', ki.quantity,
                'variant', ki.variant,
                'price', ki.price
            ))
        INTO v_kot_items_text, v_kot_items_json
        FROM public.pos_kot_items ki
        WHERE ki.kot_event_id = r_kot.kot_event_id;

        -- Push KOT_GENERATED
        v_events := v_events || jsonb_build_array(jsonb_build_object(
            'event_type', 'KOT_GENERATED',
            'title', 'KOT #' || r_kot.kot_number || ' (' || COALESCE(r_kot.kot_type, 'Normal') || ')',
            'time', r_kot.created_at,
            'formattedTime', to_char(r_kot.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
            'cashier', COALESCE(NULLIF(TRIM(r_kot.cashier_name), ''), 'POS Operator'),
            'details', 'Kitchen ticket generated. Items: ' || COALESCE(v_kot_items_text, 'None'),
            'metadata', jsonb_build_object(
                'kot_number', r_kot.kot_number,
                'kot_type', r_kot.kot_type,
                'items', COALESCE(v_kot_items_json, '[]'::jsonb),
                'print_success_count', COALESCE(r_kot.print_success_count, 0)
            )
        ));

        -- Push KOT_PRINTED only if reliable physical print timestamp evidence exists
        IF r_kot.first_printed_at IS NOT NULL OR r_kot.last_printed_at IS NOT NULL THEN
            DECLARE
                v_print_time TIMESTAMPTZ;
            BEGIN
                v_print_time := COALESCE(r_kot.first_printed_at, r_kot.last_printed_at);
                v_events := v_events || jsonb_build_array(jsonb_build_object(
                    'event_type', 'KOT_PRINTED',
                    'title', 'KOT #' || r_kot.kot_number || ' Printed',
                    'time', v_print_time,
                    'formattedTime', to_char(v_print_time AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
                    'cashier', COALESCE(NULLIF(TRIM(r_kot.cashier_name), ''), 'POS Operator'),
                    'details', 'Kitchen ticket physically printed. Print count: ' || COALESCE(r_kot.print_success_count, 1)::text,
                    'metadata', jsonb_build_object(
                        'kot_number', r_kot.kot_number,
                        'print_success_count', COALESCE(r_kot.print_success_count, 1)
                    )
                ));
            END;
        END IF;
    END LOOP;

    -- 7. EVENT 4: KOT_CORRECTED (Durable Immutable Correction Ledger)
    FOR r_corr IN (
        SELECT c.*
        FROM public.kot_corrections c
        WHERE c.order_id = p_order_id
        ORDER BY c.id ASC
    ) LOOP
        v_events := v_events || jsonb_build_array(jsonb_build_object(
            'event_type', 'KOT_CORRECTED',
            'title', 'Item Correction: ' || COALESCE(r_corr.product_name, 'Item'),
            'time', r_corr.created_at,
            'formattedTime', to_char(r_corr.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
            'cashier', COALESCE(NULLIF(TRIM(r_corr.cashier), ''), 'POS Operator'),
            'details', 'Item ' || COALESCE(r_corr.product_name, 'Item') || 
                       ' quantity changed from ' || r_corr.old_qty::text || 
                       ' to ' || r_corr.new_qty::text || 
                       '. Reason: ' || COALESCE(r_corr.reason, 'Not specified'),
            'metadata', jsonb_build_object(
                'product_name', r_corr.product_name,
                'variant_name', r_corr.variant_name,
                'old_qty', r_corr.old_qty,
                'new_qty', r_corr.new_qty,
                'delta_qty', r_corr.delta_qty,
                'reason', r_corr.reason,
                'kot_number', r_corr.kot_number
            )
        ));
    END LOOP;

    -- 8. EVENT 5: TABLE_REQUEST (Strict session_id match to table_sessions.id)
    IF v_order.table_session_id IS NOT NULL THEN
        FOR r_notif IN (
            SELECT n.*
            FROM public.pos_table_notifications n
            WHERE n.session_id = v_order.table_session_id
            ORDER BY n.id ASC
        ) LOOP
            v_events := v_events || jsonb_build_array(jsonb_build_object(
                'event_type', 'TABLE_REQUEST',
                'title', 'Customer Request: ' || COALESCE(r_notif.type, 'Activity'),
                'time', r_notif.created_at,
                'formattedTime', to_char(r_notif.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
                'cashier', 'Customer / POS',
                'details', 'Table request (' || COALESCE(r_notif.type, 'Activity') || '). Status: ' || COALESCE(r_notif.status, 'pending'),
                'metadata', jsonb_build_object(
                    'type', r_notif.type,
                    'status', r_notif.status
                )
            ));
        END LOOP;
    END IF;

    -- 9. EVENT 6: PAYMENT_SETTLED / ORDER_CLOSED (Authoritative completed state)
    IF lower(COALESCE(v_order.status, '')) IN ('closed', 'settled', 'completed') OR
       lower(COALESCE(v_order.payment_status, '')) IN ('completed', 'paid') THEN
        DECLARE
            v_settle_time TIMESTAMPTZ;
            v_order_operator TEXT;
        BEGIN
            v_settle_time := COALESCE(v_closed_at, v_order.updated_at, v_order.created_at);
            v_order_operator := COALESCE(NULLIF(TRIM(v_order.updated_by), ''), 'POS Operator');
            
            v_events := v_events || jsonb_build_array(jsonb_build_object(
                'event_type', 'PAYMENT_SETTLED',
                'title', 'Payment Completed & Closed',
                'time', v_settle_time,
                'formattedTime', to_char(v_settle_time AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
                'cashier', v_order_operator,
                'details', 'Order payment of ₹' || TRIM(to_char(COALESCE(v_order.total, 0), 'FM999990.00')) || 
                           ' completed via ' || COALESCE(v_order.payment_method, 'Cash') || '. Order Closed.',
                'metadata', jsonb_build_object(
                    'total', v_order.total,
                    'payment_method', v_order.payment_method,
                    'payment_status', v_order.payment_status,
                    'status', v_order.status
                )
            ));
        END;
    END IF;

    -- 10. EVENT 7: ORDER_CANCELLED (Authoritative cancellation state)
    IF lower(COALESCE(v_order.status, '')) IN ('cancelled', 'voided') THEN
        DECLARE
            v_cancel_time TIMESTAMPTZ;
            v_order_operator TEXT;
        BEGIN
            v_cancel_time := COALESCE(v_order.updated_at, v_order.created_at);
            v_order_operator := COALESCE(NULLIF(TRIM(v_order.updated_by), ''), 'POS Operator');

            v_events := v_events || jsonb_build_array(jsonb_build_object(
                'event_type', 'ORDER_CANCELLED',
                'title', 'Order Cancelled',
                'time', v_cancel_time,
                'formattedTime', to_char(v_cancel_time AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
                'cashier', v_order_operator,
                'details', 'Order cancelled/voided. Reason: ' || COALESCE(v_order.cancel_reason, 'Not specified'),
                'metadata', jsonb_build_object(
                    'cancel_reason', v_order.cancel_reason,
                    'status', v_order.status
                )
            ));
        END;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'order_id', v_order.id,
        'order_context', jsonb_build_object(
            'id', v_order.id,
            'order_number', v_order.order_number,
            'table_id', v_order.table_id,
            'table_session_id', v_order.table_session_id,
            'table_name', v_table_name,
            'customer_name', v_order.customer_name,
            'delivery_mode', v_order.delivery_mode,
            'status', v_order.status,
            'payment_status', v_order.payment_status,
            'payment_method', v_order.payment_method,
            'total', v_order.total,
            'created_at', v_order.created_at
        ),
        'events', v_events
    );
END;
$$;

CREATE OR REPLACE FUNCTION public._ready_inventory_movements_immutable()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
    RAISE EXCEPTION 'READY_INVENTORY_MOVEMENT_IMMUTABLE';
END;
$$;

CREATE OR REPLACE FUNCTION public._ready_inventory_mapping_variant_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
    IF NEW.variant_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.product_variants pv
        WHERE pv.id = NEW.variant_id AND pv.product_id = NEW.product_id
    ) THEN
        RAISE EXCEPTION 'READY_INVENTORY_VARIANT_PRODUCT_MISMATCH';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public._ready_inventory_authorize(p_session_token TEXT)
RETURNS TABLE (ok BOOLEAN, user_id BIGINT, user_role TEXT, error_code TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
BEGIN
    IF p_session_token IS NULL OR btrim(p_session_token) = '' THEN
        RETURN QUERY SELECT FALSE, NULL::BIGINT, NULL::TEXT, 'UNAUTHORIZED'::TEXT;
        RETURN;
    END IF;
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF v_auth IS NULL OR NOT COALESCE(v_auth.is_valid, FALSE) THEN
        RETURN QUERY SELECT FALSE, NULL::BIGINT, NULL::TEXT, COALESCE(v_auth.error_code, 'UNAUTHORIZED')::TEXT;
        RETURN;
    END IF;
    IF lower(btrim(COALESCE(v_auth.role, ''))) NOT IN ('super_admin', 'admin') THEN
        RETURN QUERY SELECT FALSE, v_auth.user_id, v_auth.role, 'PERMISSION_DENIED'::TEXT;
        RETURN;
    END IF;
    RETURN QUERY SELECT TRUE, v_auth.user_id, v_auth.role, NULL::TEXT;
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_ready_inventory_list_items(
    p_session_token TEXT,
    p_include_inactive BOOLEAN DEFAULT TRUE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_items JSONB;
BEGIN
    SELECT * INTO v_auth FROM public._ready_inventory_authorize(p_session_token);
    IF NOT v_auth.ok THEN
        RETURN jsonb_build_object('success', false, 'error', v_auth.error_code);
    END IF;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', i.id,
        'name', i.name,
        'unit', i.unit,
        'current_stock', i.current_stock,
        'low_stock_level', i.low_stock_level,
        'is_active', i.is_active,
        'stock_status', CASE
            WHEN i.current_stock < 0 THEN 'NEGATIVE'
            WHEN i.current_stock = 0 THEN 'OUT_OF_STOCK'
            WHEN i.current_stock <= i.low_stock_level THEN 'LOW_STOCK'
            ELSE 'IN_STOCK' END,
        'active_mapping_count', (SELECT count(*) FROM public.ready_inventory_menu_mappings m WHERE m.ready_item_id = i.id AND m.is_active),
        'created_at', i.created_at,
        'updated_at', i.updated_at
    ) ORDER BY i.is_active DESC, lower(i.name)), '[]'::jsonb)
    INTO v_items
    FROM public.ready_inventory_items i
    WHERE p_include_inactive OR i.is_active;

    RETURN jsonb_build_object('success', true, 'items', v_items);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNEXPECTED_ERROR', 'message', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_ready_inventory_list_movements(
    p_session_token TEXT,
    p_ready_item_id BIGINT DEFAULT NULL,
    p_limit INTEGER DEFAULT 200,
    p_offset INTEGER DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_limit INTEGER := LEAST(GREATEST(COALESCE(p_limit, 200), 1), 500);
    v_offset INTEGER := GREATEST(COALESCE(p_offset, 0), 0);
    v_rows JSONB;
    v_total BIGINT;
BEGIN
    SELECT * INTO v_auth FROM public._ready_inventory_authorize(p_session_token);
    IF NOT v_auth.ok THEN
        RETURN jsonb_build_object('success', false, 'error', v_auth.error_code);
    END IF;

    SELECT count(*) INTO v_total
    FROM public.ready_inventory_movements mv
    WHERE p_ready_item_id IS NULL OR mv.ready_item_id = p_ready_item_id;

    SELECT COALESCE(jsonb_agg(r.obj ORDER BY r.created_at DESC, r.id DESC), '[]'::jsonb)
    INTO v_rows
    FROM (
        SELECT mv.id, mv.created_at, jsonb_build_object(
            'id', mv.id,
            'created_at', mv.created_at,
            'ready_item_id', mv.ready_item_id,
            'ready_item_name', i.name,
            'unit', i.unit,
            'movement_type', mv.movement_type,
            'quantity_delta', mv.quantity_delta,
            'stock_before', mv.stock_before,
            'stock_after', mv.stock_after,
            'source_type', mv.source_type,
            'reason', mv.reason,
            'created_by', mv.created_by,
            'created_by_name', (SELECT u.full_name FROM public.users u WHERE u.id::text = mv.created_by LIMIT 1)
        ) AS obj
        FROM public.ready_inventory_movements mv
        JOIN public.ready_inventory_items i ON i.id = mv.ready_item_id
        WHERE p_ready_item_id IS NULL OR mv.ready_item_id = p_ready_item_id
        ORDER BY mv.created_at DESC, mv.id DESC
        LIMIT v_limit OFFSET v_offset
    ) r;

    RETURN jsonb_build_object('success', true, 'movements', v_rows, 'total', v_total, 'limit', v_limit, 'offset', v_offset);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNEXPECTED_ERROR', 'message', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_ready_inventory_list_mappings(
    p_session_token TEXT,
    p_include_inactive BOOLEAN DEFAULT FALSE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_rows JSONB;
BEGIN
    SELECT * INTO v_auth FROM public._ready_inventory_authorize(p_session_token);
    IF NOT v_auth.ok THEN
        RETURN jsonb_build_object('success', false, 'error', v_auth.error_code);
    END IF;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', m.id,
        'product_id', m.product_id,
        'product_name', p.name,
        'variant_id', m.variant_id,
        'variant_name', pv.name,
        'ready_item_id', m.ready_item_id,
        'ready_item_name', i.name,
        'ready_item_unit', i.unit,
        'ready_item_active', i.is_active,
        'qty_per_sale', m.qty_per_sale,
        'is_active', m.is_active,
        'updated_at', m.updated_at
    ) ORDER BY m.is_active DESC, lower(p.name), lower(COALESCE(pv.name, '')), lower(i.name)), '[]'::jsonb)
    INTO v_rows
    FROM public.ready_inventory_menu_mappings m
    JOIN public.products p ON p.id = m.product_id
    LEFT JOIN public.product_variants pv ON pv.id = m.variant_id
    JOIN public.ready_inventory_items i ON i.id = m.ready_item_id
    WHERE p_include_inactive OR m.is_active;

    RETURN jsonb_build_object('success', true, 'mappings', v_rows);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNEXPECTED_ERROR', 'message', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_ready_inventory_list_menu_products(p_session_token TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_rows JSONB;
BEGIN
    SELECT * INTO v_auth FROM public._ready_inventory_authorize(p_session_token);
    IF NOT v_auth.ok THEN
        RETURN jsonb_build_object('success', false, 'error', v_auth.error_code);
    END IF;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', p.id,
        'name', p.name,
        'variants', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('id', pv.id, 'name', pv.name) ORDER BY pv.price, pv.id)
            FROM public.product_variants pv
            WHERE pv.product_id = p.id
        ), '[]'::jsonb)
    ) ORDER BY lower(p.name)), '[]'::jsonb)
    INTO v_rows
    FROM public.products p;

    RETURN jsonb_build_object('success', true, 'products', v_rows);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNEXPECTED_ERROR', 'message', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_ready_inventory_adjust(
    p_session_token TEXT,
    p_ready_item_id BIGINT,
    p_movement_type TEXT,
    p_quantity NUMERIC,
    p_reason TEXT,
    p_client_request_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_type TEXT := upper(btrim(COALESCE(p_movement_type, '')));
    v_reason TEXT := NULLIF(btrim(COALESCE(p_reason, '')), '');
    v_item RECORD;
    v_existing RECORD;
    v_delta NUMERIC(12,3);
    v_before NUMERIC(12,3);
    v_after NUMERIC(12,3);
    v_movement_id BIGINT;
BEGIN
    SELECT * INTO v_auth FROM public._ready_inventory_authorize(p_session_token);
    IF NOT v_auth.ok THEN
        RETURN jsonb_build_object('success', false, 'error', v_auth.error_code);
    END IF;

    IF p_client_request_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'MISSING_CLIENT_REQUEST_ID');
    END IF;
    IF v_type NOT IN ('OPENING', 'PURCHASE', 'ADJUSTMENT_IN', 'ADJUSTMENT_OUT') THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_MOVEMENT_TYPE');
    END IF;
    IF p_quantity IS NULL OR p_quantity <= 0 OR p_quantity > 1000000 OR p_quantity <> round(p_quantity, 3) THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_QUANTITY');
    END IF;
    IF v_type IN ('ADJUSTMENT_IN', 'ADJUSTMENT_OUT') AND v_reason IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'REASON_REQUIRED');
    END IF;
    IF v_reason IS NOT NULL AND length(v_reason) > 300 THEN
        RETURN jsonb_build_object('success', false, 'error', 'REASON_TOO_LONG');
    END IF;

    -- Serialize every stock change for this item.
    SELECT * INTO v_item FROM public.ready_inventory_items WHERE id = p_ready_item_id FOR UPDATE;
    IF v_item.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'ITEM_NOT_FOUND');
    END IF;

    -- Idempotency: same request id => same result, never a second movement.
    SELECT * INTO v_existing FROM public.ready_inventory_movements WHERE client_request_id = p_client_request_id;
    IF v_existing.id IS NOT NULL THEN
        IF v_existing.ready_item_id = p_ready_item_id
           AND v_existing.movement_type = v_type
           AND abs(v_existing.quantity_delta) = round(p_quantity, 3) THEN
            RETURN jsonb_build_object(
                'success', true,
                'idempotent_replay', true,
                'movement_id', v_existing.id,
                'ready_item_id', p_ready_item_id,
                'current_stock', v_item.current_stock
            );
        END IF;
        RETURN jsonb_build_object('success', false, 'error', 'IDEMPOTENCY_PAYLOAD_MISMATCH');
    END IF;

    IF v_type = 'OPENING' AND EXISTS (SELECT 1 FROM public.ready_inventory_movements WHERE ready_item_id = p_ready_item_id) THEN
        RETURN jsonb_build_object('success', false, 'error', 'OPENING_ALREADY_RECORDED');
    END IF;

    v_delta := CASE WHEN v_type = 'ADJUSTMENT_OUT' THEN -round(p_quantity, 3) ELSE round(p_quantity, 3) END;
    v_before := v_item.current_stock;
    v_after := v_before + v_delta;   -- negative stock is allowed

    INSERT INTO public.ready_inventory_movements (
        ready_item_id, movement_type, quantity_delta, stock_before, stock_after,
        source_type, reason, created_by, client_request_id
    ) VALUES (
        p_ready_item_id, v_type, v_delta, v_before, v_after,
        'MANUAL', v_reason, v_auth.user_id::text, p_client_request_id
    ) RETURNING id INTO v_movement_id;

    UPDATE public.ready_inventory_items
    SET current_stock = v_after, updated_at = now(), updated_by = v_auth.user_id::text
    WHERE id = p_ready_item_id;

    RETURN jsonb_build_object(
        'success', true,
        'idempotent_replay', false,
        'movement_id', v_movement_id,
        'ready_item_id', p_ready_item_id,
        'stock_before', v_before,
        'stock_after', v_after,
        'current_stock', v_after
    );
EXCEPTION
    WHEN unique_violation THEN
        -- Concurrent duplicate client_request_id: the other transaction won.
        RETURN jsonb_build_object('success', false, 'error', 'DUPLICATE_REQUEST');
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'error', 'UNEXPECTED_ERROR', 'message', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_ready_inventory_save_item(
    p_session_token TEXT,
    p_item_id BIGINT,
    p_name TEXT,
    p_unit TEXT,
    p_low_stock_level NUMERIC,
    p_is_active BOOLEAN DEFAULT TRUE,
    p_opening_stock NUMERIC DEFAULT NULL,
    p_client_request_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_name TEXT := btrim(COALESCE(p_name, ''));
    v_unit TEXT := btrim(COALESCE(p_unit, ''));
    v_low NUMERIC := COALESCE(p_low_stock_level, 0);
    v_id BIGINT;
    v_existing RECORD;
    v_replay RECORD;
BEGIN
    SELECT * INTO v_auth FROM public._ready_inventory_authorize(p_session_token);
    IF NOT v_auth.ok THEN
        RETURN jsonb_build_object('success', false, 'error', v_auth.error_code);
    END IF;

    IF length(v_name) < 1 OR length(v_name) > 120 THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_NAME');
    END IF;
    IF length(v_unit) < 1 OR length(v_unit) > 30 THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_UNIT');
    END IF;
    IF v_low < 0 OR v_low > 1000000 OR v_low <> round(v_low, 3) THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_LOW_STOCK_LEVEL');
    END IF;

    IF p_item_id IS NULL THEN
        -- CREATE
        IF p_opening_stock IS NOT NULL THEN
            IF p_opening_stock < 0 OR p_opening_stock > 1000000 OR p_opening_stock <> round(p_opening_stock, 3) THEN
                RETURN jsonb_build_object('success', false, 'error', 'INVALID_OPENING_STOCK');
            END IF;
            IF p_opening_stock > 0 AND p_client_request_id IS NULL THEN
                RETURN jsonb_build_object('success', false, 'error', 'MISSING_CLIENT_REQUEST_ID');
            END IF;
        END IF;

        -- Idempotent create: a retried create with the same request id
        -- returns the item its OPENING movement belongs to.
        IF p_client_request_id IS NOT NULL THEN
            SELECT * INTO v_replay FROM public.ready_inventory_movements WHERE client_request_id = p_client_request_id;
            IF v_replay.id IS NOT NULL THEN
                RETURN jsonb_build_object('success', true, 'idempotent_replay', true, 'item_id', v_replay.ready_item_id);
            END IF;
        END IF;

        INSERT INTO public.ready_inventory_items (name, unit, low_stock_level, is_active, current_stock, updated_by)
        VALUES (v_name, v_unit, round(v_low, 3), true, 0, v_auth.user_id::text)
        RETURNING id INTO v_id;

        IF COALESCE(p_opening_stock, 0) > 0 THEN
            INSERT INTO public.ready_inventory_movements (
                ready_item_id, movement_type, quantity_delta, stock_before, stock_after,
                source_type, reason, created_by, client_request_id
            ) VALUES (
                v_id, 'OPENING', round(p_opening_stock, 3), 0, round(p_opening_stock, 3),
                'MANUAL', 'Opening stock', v_auth.user_id::text, p_client_request_id
            );
            UPDATE public.ready_inventory_items SET current_stock = round(p_opening_stock, 3) WHERE id = v_id;
        END IF;

        RETURN jsonb_build_object('success', true, 'idempotent_replay', false, 'item_id', v_id);
    END IF;

    -- EDIT (metadata only; current_stock is never touched here)
    SELECT * INTO v_existing FROM public.ready_inventory_items WHERE id = p_item_id FOR UPDATE;
    IF v_existing.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'ITEM_NOT_FOUND');
    END IF;
    IF p_opening_stock IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'STOCK_NOT_EDITABLE_USE_ADJUSTMENT');
    END IF;

    UPDATE public.ready_inventory_items
    SET name = v_name,
        unit = v_unit,
        low_stock_level = round(v_low, 3),
        is_active = COALESCE(p_is_active, v_existing.is_active),
        updated_at = now(),
        updated_by = v_auth.user_id::text
    WHERE id = p_item_id;

    RETURN jsonb_build_object('success', true, 'item_id', p_item_id);
EXCEPTION
    WHEN unique_violation THEN
        RETURN jsonb_build_object('success', false, 'error', 'DUPLICATE_ITEM_NAME');
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'error', 'UNEXPECTED_ERROR', 'message', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_ready_inventory_save_mapping(
    p_session_token TEXT,
    p_mapping_id BIGINT,
    p_product_id BIGINT,
    p_variant_id BIGINT,
    p_ready_item_id BIGINT,
    p_qty_per_sale NUMERIC
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_has_variants BOOLEAN;
    v_item RECORD;
    v_existing RECORD;
    v_id BIGINT;
BEGIN
    SELECT * INTO v_auth FROM public._ready_inventory_authorize(p_session_token);
    IF NOT v_auth.ok THEN
        RETURN jsonb_build_object('success', false, 'error', v_auth.error_code);
    END IF;

    IF p_product_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.products WHERE id = p_product_id) THEN
        RETURN jsonb_build_object('success', false, 'error', 'PRODUCT_NOT_FOUND');
    END IF;

    SELECT EXISTS (SELECT 1 FROM public.product_variants WHERE product_id = p_product_id) INTO v_has_variants;
    IF p_variant_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM public.product_variants WHERE id = p_variant_id AND product_id = p_product_id) THEN
            RETURN jsonb_build_object('success', false, 'error', 'VARIANT_NOT_IN_PRODUCT');
        END IF;
    ELSIF v_has_variants THEN
        RETURN jsonb_build_object('success', false, 'error', 'VARIANT_REQUIRED');
    END IF;

    SELECT * INTO v_item FROM public.ready_inventory_items WHERE id = p_ready_item_id;
    IF v_item.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'ITEM_NOT_FOUND');
    END IF;
    IF NOT v_item.is_active THEN
        RETURN jsonb_build_object('success', false, 'error', 'ITEM_INACTIVE');
    END IF;

    IF p_qty_per_sale IS NULL OR p_qty_per_sale <= 0 OR p_qty_per_sale > 1000 OR p_qty_per_sale <> round(p_qty_per_sale, 3) THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_QTY_PER_SALE');
    END IF;

    IF p_mapping_id IS NULL THEN
        INSERT INTO public.ready_inventory_menu_mappings (product_id, variant_id, ready_item_id, qty_per_sale, is_active, updated_by)
        VALUES (p_product_id, p_variant_id, p_ready_item_id, round(p_qty_per_sale, 3), true, v_auth.user_id::text)
        RETURNING id INTO v_id;
        RETURN jsonb_build_object('success', true, 'mapping_id', v_id);
    END IF;

    SELECT * INTO v_existing FROM public.ready_inventory_menu_mappings WHERE id = p_mapping_id FOR UPDATE;
    IF v_existing.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'MAPPING_NOT_FOUND');
    END IF;
    IF NOT v_existing.is_active THEN
        RETURN jsonb_build_object('success', false, 'error', 'MAPPING_DISCONNECTED');
    END IF;

    UPDATE public.ready_inventory_menu_mappings
    SET product_id = p_product_id,
        variant_id = p_variant_id,
        ready_item_id = p_ready_item_id,
        qty_per_sale = round(p_qty_per_sale, 3),
        updated_at = now(),
        updated_by = v_auth.user_id::text
    WHERE id = p_mapping_id;

    RETURN jsonb_build_object('success', true, 'mapping_id', p_mapping_id);
EXCEPTION
    WHEN unique_violation THEN
        RETURN jsonb_build_object('success', false, 'error', 'DUPLICATE_MAPPING');
    WHEN OTHERS THEN
        IF SQLERRM LIKE '%READY_INVENTORY_VARIANT_PRODUCT_MISMATCH%' THEN
            RETURN jsonb_build_object('success', false, 'error', 'VARIANT_NOT_IN_PRODUCT');
        END IF;
        RETURN jsonb_build_object('success', false, 'error', 'UNEXPECTED_ERROR', 'message', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_ready_inventory_disconnect_mapping(
    p_session_token TEXT,
    p_mapping_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_existing RECORD;
BEGIN
    SELECT * INTO v_auth FROM public._ready_inventory_authorize(p_session_token);
    IF NOT v_auth.ok THEN
        RETURN jsonb_build_object('success', false, 'error', v_auth.error_code);
    END IF;

    SELECT * INTO v_existing FROM public.ready_inventory_menu_mappings WHERE id = p_mapping_id FOR UPDATE;
    IF v_existing.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'MAPPING_NOT_FOUND');
    END IF;
    IF NOT v_existing.is_active THEN
        RETURN jsonb_build_object('success', true, 'idempotent_replay', true, 'mapping_id', p_mapping_id);
    END IF;

    UPDATE public.ready_inventory_menu_mappings
    SET is_active = false, updated_at = now(), updated_by = v_auth.user_id::text
    WHERE id = p_mapping_id;

    RETURN jsonb_build_object('success', true, 'mapping_id', p_mapping_id);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNEXPECTED_ERROR', 'message', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION public._ready_inventory_deduct_pos_sale(p_master_order_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_master_order RECORD;
    v_order_number TEXT;
    v_session_id BIGINT;
    item RECORD;
    m RECORD;
    v_variant_name TEXT;
    v_has_variant_name BOOLEAN;
    v_matching_variant_count INTEGER;
    v_product_variant_count INTEGER;
    v_resolved_variant_id BIGINT;
    v_target_variant_id BIGINT;
    v_can_process_line BOOLEAN;
    v_source_line_key TEXT;
    v_delta NUMERIC(12,3);
    v_item_row RECORD;
    v_before NUMERIC(12,3);
    v_after NUMERIC(12,3);
    v_inserted_id BIGINT;
BEGIN
    IF p_master_order_id IS NULL THEN
        RETURN;
    END IF;

    SELECT id, order_number, table_session_id INTO v_master_order
    FROM public.pos_orders
    WHERE id = p_master_order_id;

    IF v_master_order.id IS NULL THEN
        RETURN;
    END IF;

    v_order_number := COALESCE(v_master_order.order_number, v_master_order.id::text);
    v_session_id := v_master_order.table_session_id;

    -- Query ALL eligible physical order items across master order AND non-cancelled sibling orders in table_session_id
    FOR item IN
        SELECT oi.id AS pos_order_item_id, oi.product_id, oi.variant_name, oi.quantity
        FROM public.pos_order_items oi
        JOIN public.pos_orders o ON o.id = oi.order_id
        WHERE (
            o.id = p_master_order_id
            OR (v_session_id IS NOT NULL AND o.table_session_id = v_session_id)
        )
        AND lower(COALESCE(o.status, '')) NOT IN ('cancelled', 'rejected', 'voided', 'deleted')
        AND lower(COALESCE(oi.status, '')) NOT IN ('cancelled', 'rejected', 'voided')
        AND oi.product_id IS NOT NULL
        AND oi.quantity IS NOT NULL
        AND oi.quantity > 0
    LOOP
        v_variant_name := btrim(COALESCE(item.variant_name, ''));
        v_has_variant_name := (length(v_variant_name) > 0);

        -- [Phase 1B non-variant resolution fix] Variant identity is decided by
        -- the product's REAL product_variants rows, never by the display label.
        SELECT COUNT(*) INTO v_product_variant_count
        FROM public.product_variants
        WHERE product_id = item.product_id;

        IF v_product_variant_count = 0 THEN
            -- CASE 1: product has NO real variants -> non-variant product.
            -- Any line label (e.g. the POS default 'Regular', or empty) is
            -- synthetic; match ONLY mappings with variant_id IS NULL.
            v_target_variant_id := NULL;
            v_can_process_line := TRUE;
        ELSIF NOT v_has_variant_name THEN
            -- CASE 2: product HAS real variants but the line names none ->
            -- cannot identify the variant; SKIP (never fall back to NULL mapping).
            v_can_process_line := FALSE;
        ELSE
            -- CASE 3: product HAS real variants -> the label must resolve to
            -- exactly one real variant of THIS product; otherwise SKIP.
            SELECT COUNT(*), MAX(id) INTO v_matching_variant_count, v_resolved_variant_id
            FROM public.product_variants
            WHERE product_id = item.product_id
              AND lower(btrim(name)) = lower(v_variant_name);

            IF v_matching_variant_count = 1 AND v_resolved_variant_id IS NOT NULL THEN
                v_target_variant_id := v_resolved_variant_id;
                v_can_process_line := TRUE;
            ELSE
                v_can_process_line := FALSE;
            END IF;
        END IF;

        IF v_can_process_line THEN
            -- Process ALL matching active mappings for (product_id, v_target_variant_id)
            FOR m IN
                SELECT id, ready_item_id, qty_per_sale
                FROM public.ready_inventory_menu_mappings
                WHERE product_id = item.product_id
                  AND (
                      (v_target_variant_id IS NULL AND variant_id IS NULL)
                      OR (v_target_variant_id IS NOT NULL AND variant_id = v_target_variant_id)
                  )
                  AND is_active = TRUE
            LOOP
                v_source_line_key := 'POS:' || item.pos_order_item_id || ':' || m.id;
                v_delta := -round(item.quantity * m.qty_per_sale, 3);

                -- Lock target ready item row FOR UPDATE
                SELECT * INTO v_item_row
                FROM public.ready_inventory_items
                WHERE id = m.ready_item_id
                FOR UPDATE;

                IF v_item_row.id IS NOT NULL THEN
                    v_before := v_item_row.current_stock;
                    v_after := v_before + v_delta;
                    v_inserted_id := NULL;

                    -- Attempt movement insertion exactly once
                    INSERT INTO public.ready_inventory_movements (
                        ready_item_id, movement_type, quantity_delta, stock_before, stock_after,
                        source_type, reason, created_by, source_line_key
                    ) VALUES (
                        m.ready_item_id, 'SALE', v_delta, v_before, v_after,
                        'POS', 'POS Order #' || v_order_number, 'SYSTEM', v_source_line_key
                    )
                    ON CONFLICT (source_line_key) WHERE source_line_key IS NOT NULL DO NOTHING
                    RETURNING id INTO v_inserted_id;

                    -- ONLY if INSERT actually succeeded (new movement inserted): update current_stock
                    IF v_inserted_id IS NOT NULL THEN
                        UPDATE public.ready_inventory_items
                        SET current_stock = v_after,
                            updated_at = now(),
                            updated_by = 'SYSTEM'
                        WHERE id = m.ready_item_id;
                    END IF;
                END IF;
            END LOOP;
        END IF;
    END LOOP;

    -- On successful helper completion (or idempotent success), mark any prior failure as resolved
    UPDATE public.ready_inventory_sale_failures
    SET resolved = TRUE,
        resolved_at = now(),
        resolved_by = 'SYSTEM'
    WHERE source_type = 'POS'
      AND source_order_id = p_master_order_id
      AND operation = 'SALE_DEDUCTION'
      AND resolved = FALSE;
END;
$$;

CREATE OR REPLACE FUNCTION public._ready_inventory_deduct_website_sale(p_order_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_order RECORD;
    v_order_number TEXT;
    item RECORD;
    m RECORD;
    v_variant_name TEXT;
    v_has_variant_name BOOLEAN;
    v_matching_variant_count INTEGER;
    v_product_variant_count INTEGER;
    v_resolved_variant_id BIGINT;
    v_target_variant_id BIGINT;
    v_can_process_line BOOLEAN;
    v_source_line_key TEXT;
    v_delta NUMERIC(12,3);
    v_item_row RECORD;
    v_before NUMERIC(12,3);
    v_after NUMERIC(12,3);
    v_inserted_id BIGINT;
BEGIN
    IF p_order_id IS NULL THEN
        RETURN;
    END IF;

    -- Fix: public.orders primary key is 'id'. Column 'order_number' does not exist on public.orders.
    SELECT id INTO v_order
    FROM public.orders
    WHERE id = p_order_id;

    IF v_order.id IS NULL THEN
        RETURN;
    END IF;

    v_order_number := v_order.id::text;

    FOR item IN
        SELECT oi.id AS order_item_id, oi.product_id, oi.variant_name, oi.quantity
        FROM public.order_items oi
        WHERE oi.order_id = p_order_id
          AND oi.product_id IS NOT NULL
          AND oi.quantity IS NOT NULL
          AND oi.quantity > 0
    LOOP
        v_variant_name := btrim(COALESCE(item.variant_name, ''));
        v_has_variant_name := (length(v_variant_name) > 0);

        -- [Phase 1B non-variant resolution fix] Variant identity is decided by
        -- the product's REAL product_variants rows, never by the display label.
        SELECT COUNT(*) INTO v_product_variant_count
        FROM public.product_variants
        WHERE product_id = item.product_id;

        IF v_product_variant_count = 0 THEN
            -- CASE 1: product has NO real variants -> non-variant product.
            -- Any line label (e.g. default 'Regular', or empty) is synthetic;
            -- match ONLY mappings with variant_id IS NULL.
            v_target_variant_id := NULL;
            v_can_process_line := TRUE;
        ELSIF NOT v_has_variant_name THEN
            -- CASE 2: product HAS real variants but the line names none ->
            -- cannot identify the variant; SKIP (never fall back to NULL mapping).
            v_can_process_line := FALSE;
        ELSE
            -- CASE 3: product HAS real variants -> the label must resolve to
            -- exactly one real variant of THIS product; otherwise SKIP.
            SELECT COUNT(*), MAX(id) INTO v_matching_variant_count, v_resolved_variant_id
            FROM public.product_variants
            WHERE product_id = item.product_id
              AND lower(btrim(name)) = lower(v_variant_name);

            IF v_matching_variant_count = 1 AND v_resolved_variant_id IS NOT NULL THEN
                v_target_variant_id := v_resolved_variant_id;
                v_can_process_line := TRUE;
            ELSE
                v_can_process_line := FALSE;
            END IF;
        END IF;

        IF v_can_process_line THEN
            -- Process ALL matching active mappings for (product_id, v_target_variant_id)
            FOR m IN
                SELECT id, ready_item_id, qty_per_sale
                FROM public.ready_inventory_menu_mappings
                WHERE product_id = item.product_id
                  AND (
                      (v_target_variant_id IS NULL AND variant_id IS NULL)
                      OR (v_target_variant_id IS NOT NULL AND variant_id = v_target_variant_id)
                  )
                  AND is_active = TRUE
            LOOP
                v_source_line_key := 'WEB:' || item.order_item_id || ':' || m.id;
                v_delta := -round(item.quantity * m.qty_per_sale, 3);

                -- Lock target ready item row FOR UPDATE
                SELECT * INTO v_item_row
                FROM public.ready_inventory_items
                WHERE id = m.ready_item_id
                FOR UPDATE;

                IF v_item_row.id IS NOT NULL THEN
                    v_before := v_item_row.current_stock;
                    v_after := v_before + v_delta;
                    v_inserted_id := NULL;

                    -- Attempt movement insertion exactly once
                    INSERT INTO public.ready_inventory_movements (
                        ready_item_id, movement_type, quantity_delta, stock_before, stock_after,
                        source_type, reason, created_by, source_line_key
                    ) VALUES (
                        m.ready_item_id, 'SALE', v_delta, v_before, v_after,
                        'WEBSITE', 'Website Order #' || v_order_number, 'SYSTEM', v_source_line_key
                    )
                    ON CONFLICT (source_line_key) WHERE source_line_key IS NOT NULL DO NOTHING
                    RETURNING id INTO v_inserted_id;

                    -- ONLY if INSERT actually succeeded (new movement inserted): update current_stock
                    IF v_inserted_id IS NOT NULL THEN
                        UPDATE public.ready_inventory_items
                        SET current_stock = v_after,
                            updated_at = now(),
                            updated_by = 'SYSTEM'
                        WHERE id = m.ready_item_id;
                    END IF;
                END IF;
            END LOOP;
        END IF;
    END LOOP;

    -- On successful helper completion (or idempotent success), mark any prior failure as resolved
    UPDATE public.ready_inventory_sale_failures
    SET resolved = TRUE,
        resolved_at = now(),
        resolved_by = 'SYSTEM'
    WHERE source_type = 'WEBSITE'
      AND source_order_id = p_order_id
      AND operation = 'SALE_DEDUCTION'
      AND resolved = FALSE;
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_transition_live_order(
    p_session_token TEXT,
    p_order_domain TEXT,
    p_order_id BIGINT,
    p_target_status TEXT,
    p_reason TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_auth RECORD;
    v_domain TEXT;
    v_target_status TEXT;
    v_order_rec RECORD;
    v_curr_status TEXT;
    v_curr_status_upper TEXT;
    v_target_status_upper TEXT;
    v_delivery_mode TEXT;
    v_allowed_transition BOOLEAN := FALSE;
    v_canonical_target TEXT;
BEGIN
    -- 1. Validate Session Token via Session Helper
    SELECT * INTO v_auth
    FROM public.validate_active_session_internal(p_session_token, NULL);

    IF v_auth.is_valid IS NOT TRUE THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'UNAUTHORIZED',
            'error', COALESCE(v_auth.error_code, 'INVALID_SESSION')
        );
    END IF;

    -- Enforce Role Authorization
    IF v_auth.role IS NULL OR lower(v_auth.role) IN ('customer', 'user', 'guest') OR lower(v_auth.role) NOT IN ('super_admin', 'admin', 'manager', 'staff_admin', 'staffadmin', 'cashier', 'kitchen', 'pos_staff', 'kitchen_staff') THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'UNAUTHORIZED',
            'error', 'UNAUTHORIZED_ROLE'
        );
    END IF;

    -- 2. Domain Validation & Normalization
    v_domain := UPPER(trim(COALESCE(p_order_domain, '')));
    IF v_domain NOT IN ('WEBSITE', 'POS', 'ORDERS', 'POS_ORDERS') THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_INPUT',
            'error', 'INVALID_ORDER_DOMAIN'
        );
    END IF;

    IF v_domain = 'ORDERS' THEN v_domain := 'WEBSITE'; END IF;
    IF v_domain = 'POS_ORDERS' THEN v_domain := 'POS'; END IF;

    -- 3. Order ID Validation
    IF p_order_id IS NULL OR p_order_id <= 0 THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_INPUT',
            'error', 'INVALID_ORDER_ID'
        );
    END IF;

    -- 4. Target Status Normalization
    v_target_status := trim(COALESCE(p_target_status, ''));
    v_target_status_upper := UPPER(v_target_status);

    IF v_target_status_upper = '' THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_INPUT',
            'error', 'EMPTY_TARGET_STATUS'
        );
    END IF;

    IF v_target_status_upper = 'PREPARING' THEN v_canonical_target := 'Preparing';
    ELSIF v_target_status_upper = 'READY' THEN v_canonical_target := 'Ready';
    ELSIF v_target_status_upper = 'OUT_FOR_DELIVERY' OR v_target_status_upper = 'OUT FOR DELIVERY' THEN v_canonical_target := 'Out For Delivery';
    ELSIF v_target_status_upper = 'DELIVERED' THEN v_canonical_target := 'Delivered';
    ELSIF v_target_status_upper IN ('CANCELLED', 'CANCELED') THEN v_canonical_target := 'Cancelled';
    ELSE
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_STATUS_TRANSITION',
            'error', 'UNSUPPORTED_TARGET_STATUS'
        );
    END IF;

    -- 5. Lock Target Order FOR UPDATE
    IF v_domain = 'WEBSITE' THEN
        SELECT id, status, order_status, delivery_mode, payment_status INTO v_order_rec
        FROM public.orders
        WHERE id = p_order_id FOR UPDATE;
    ELSE
        SELECT id, status, delivery_mode, payment_status INTO v_order_rec
        FROM public.pos_orders
        WHERE id = p_order_id FOR UPDATE;
    END IF;

    IF v_order_rec.id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'ORDER_NOT_FOUND',
            'error', 'ORDER_NOT_FOUND'
        );
    END IF;

    v_curr_status := COALESCE(v_order_rec.status, '');
    v_curr_status_upper := UPPER(trim(v_curr_status));
    v_delivery_mode := LOWER(trim(COALESCE(v_order_rec.delivery_mode, 'dinein')));

    -- 6. Terminal Finality Check
    IF v_curr_status_upper IN ('CANCELLED', 'CANCELED', 'VOIDED', 'REJECTED', 'FAILED', 'REFUNDED') THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'ORDER_TERMINAL',
            'error', 'CANNOT_TRANSITION_TERMINAL_ORDER'
        );
    END IF;

    -- 7. Same-State Replay (Idempotent)
    IF v_curr_status_upper = UPPER(v_canonical_target)
       OR (v_curr_status_upper = 'OUT_FOR_DELIVERY' AND UPPER(v_canonical_target) = 'OUT FOR DELIVERY')
       OR (v_curr_status_upper = 'OUT FOR DELIVERY' AND UPPER(v_canonical_target) = 'OUT_FOR_DELIVERY') THEN
        RETURN jsonb_build_object(
            'success', true,
            'idempotent_replay', true,
            'code', 'IDEMPOTENT_REPLAY',
            'domain', v_domain,
            'order_id', p_order_id,
            'status', v_curr_status
        );
    END IF;

    -- If already DELIVERED, no further transition allowed
    IF v_curr_status_upper = 'DELIVERED' THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'ORDER_TERMINAL',
            'error', 'ORDER_ALREADY_DELIVERED'
        );
    END IF;

    -- 8. State Machine Transition Rules
    IF v_canonical_target = 'Preparing' THEN
        IF v_curr_status_upper IN ('CONFIRMED', 'OPEN', 'PENDING', 'ACCEPTED', 'PLACED') THEN
            v_allowed_transition := TRUE;
        END IF;
    ELSIF v_canonical_target = 'Ready' THEN
        IF v_curr_status_upper IN ('PREPARING', 'CONFIRMED', 'OPEN', 'ACCEPTED') THEN
            v_allowed_transition := TRUE;
        END IF;
    ELSIF v_canonical_target = 'Out For Delivery' THEN
        IF v_curr_status_upper IN ('READY', 'PREPARING') AND v_delivery_mode = 'delivery' THEN
            v_allowed_transition := TRUE;
        END IF;
    ELSIF v_canonical_target = 'Delivered' THEN
        IF v_curr_status_upper IN ('READY', 'OUT_FOR_DELIVERY', 'OUT FOR DELIVERY', 'PREPARING') THEN
            v_allowed_transition := TRUE;
        END IF;
    ELSIF v_canonical_target = 'Cancelled' THEN
        IF v_curr_status_upper IN ('CONFIRMED', 'OPEN', 'PENDING', 'ACCEPTED', 'PLACED', 'PREPARING', 'READY', 'OUT_FOR_DELIVERY', 'OUT FOR DELIVERY') THEN
            v_allowed_transition := TRUE;
        END IF;
    END IF;

    IF NOT v_allowed_transition THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_STATUS_TRANSITION',
            'error', 'INVALID_STATUS_TRANSITION'
        );
    END IF;

    -- 9. Perform State Update with Timestamp & Reason Persistence
    IF v_domain = 'WEBSITE' THEN
        IF v_canonical_target = 'Delivered' THEN
            UPDATE public.orders
            SET status = v_canonical_target,
                order_status = v_canonical_target,
                delivered_at = COALESCE(delivered_at, now())
            WHERE id = p_order_id;
        ELSIF v_canonical_target = 'Cancelled' THEN
            UPDATE public.orders
            SET status = v_canonical_target,
                order_status = v_canonical_target,
                cancelled_at = COALESCE(cancelled_at, now()),
                cancel_reason = COALESCE(NULLIF(trim(p_reason), ''), cancel_reason, 'Cancelled via Table Management')
            WHERE id = p_order_id;
        ELSE
            UPDATE public.orders
            SET status = v_canonical_target,
                order_status = v_canonical_target
            WHERE id = p_order_id;
        END IF;
    ELSE
        UPDATE public.pos_orders
        SET status = v_canonical_target
        WHERE id = p_order_id;
    END IF;

    -- 9.5 Perform Ready Inventory Phase 1B Website Sales Deduction ONLY for Delivered status
    IF v_domain = 'WEBSITE' AND v_canonical_target = 'Delivered' THEN
        BEGIN
            PERFORM public._ready_inventory_deduct_website_sale(p_order_id);
        EXCEPTION WHEN OTHERS THEN
            DECLARE
                v_err_code TEXT;
                v_err_msg TEXT;
                v_err_detail TEXT;
                v_err_hint TEXT;
                v_err_context TEXT;
            BEGIN
                GET STACKED DIAGNOSTICS
                    v_err_code    = RETURNED_SQLSTATE,
                    v_err_msg     = MESSAGE_TEXT,
                    v_err_detail  = PG_EXCEPTION_DETAIL,
                    v_err_hint    = PG_EXCEPTION_HINT,
                    v_err_context = PG_EXCEPTION_CONTEXT;

                INSERT INTO public.ready_inventory_sale_failures (
                    source_type, source_order_id, operation,
                    error_code, error_message, error_detail, error_hint, error_context,
                    retry_count, resolved, created_at, last_seen_at
                ) VALUES (
                    'WEBSITE', p_order_id, 'SALE_DEDUCTION',
                    v_err_code, v_err_msg, v_err_detail, v_err_hint, v_err_context,
                    1, FALSE, now(), now()
                )
                ON CONFLICT (source_type, source_order_id, operation) WHERE resolved = FALSE
                DO UPDATE SET
                    retry_count = ready_inventory_sale_failures.retry_count + 1,
                    last_seen_at = now(),
                    error_code = EXCLUDED.error_code,
                    error_message = EXCLUDED.error_message,
                    error_detail = EXCLUDED.error_detail,
                    error_hint = EXCLUDED.error_hint,
                    error_context = EXCLUDED.error_context;
            END;
        END;
    END IF;

    -- 10. Audit Log
    INSERT INTO public.system_audit_logs (user_name, user_role, action, details)
    VALUES (
        COALESCE(v_auth.role, 'staff'),
        v_auth.role,
        'live_order_status_transition',
        jsonb_build_object(
            'domain', v_domain,
            'order_id', p_order_id,
            'old_status', v_curr_status,
            'new_status', v_canonical_target,
            'reason', p_reason
        )
    );

    RETURN jsonb_build_object(
        'success', true,
        'code', 'SUCCESS',
        'domain', v_domain,
        'order_id', p_order_id,
        'old_status', v_curr_status,
        'new_status', v_canonical_target
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp;

CREATE OR REPLACE FUNCTION public.secure_create_order(
    p_items JSONB,
    p_delivery_mode TEXT,
    p_address TEXT,
    p_landmark TEXT,
    p_payment_method TEXT,
    p_coupon_code TEXT,
    p_use_wallet BOOLEAN,
    p_session_token TEXT,
    p_address_id BIGINT DEFAULT NULL::BIGINT,
    p_road_distance_km NUMERIC DEFAULT NULL::NUMERIC,
    p_estimated_time_minutes NUMERIC DEFAULT NULL::NUMERIC,
    p_route_geometry JSONB DEFAULT NULL::JSONB,
    p_idempotency_key TEXT DEFAULT NULL::TEXT
)
RETURNS JSONB AS $$
DECLARE
    v_session RECORD;
    v_user RECORD;
    v_wallet RECORD;
    v_wallet_settings RECORD;
    v_coupon RECORD;
    v_offer RECORD;
    v_coupon_found BOOLEAN := FALSE;
    v_delivery_settings RECORD;
    v_slab RECORD;
    v_slab_matched BOOLEAN := FALSE;
    v_slab_charge NUMERIC := 0.0;
    v_slab_free_above NUMERIC;
    v_max_slab_limit NUMERIC := 10.0;
    v_subtotal NUMERIC := 0.0;
    v_gst NUMERIC := 0.0;
    v_delivery_fee NUMERIC := 0.0;
    v_coupon_discount NUMERIC := 0.0;
    v_wallet_redeem_coins INT := 0;
    v_wallet_redeem_rupees NUMERIC := 0.0;
    v_final_total NUMERIC := 0.0;
    v_order_id BIGINT;
    v_order_item_id BIGINT;
    v_items_count INT;
    v_item_data JSONB;
    v_product RECORD;
    v_item_price NUMERIC;
    v_variant_name TEXT;
    v_addons_names TEXT;
    v_addr_lat NUMERIC;
    v_addr_lng NUMERIC;
    v_addr_map_link TEXT;
    v_distance NUMERIC;
    v_store_lat NUMERIC := 27.795029;
    v_store_lng NUMERIC := 76.643329;
    v_init_payment_status TEXT;
    v_init_order_status TEXT;
    v_init_status TEXT;
    v_cust_name TEXT;
    v_cust_phone TEXT;
    v_existing_order RECORD;
BEGIN
    -- 1. Validate Session Token FIRST
    SELECT * INTO v_session FROM public.active_sessions WHERE token = p_session_token AND expires_at > NOW() LIMIT 1;
    IF v_session IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid or expired session. Please login again.');
    END IF;

    SELECT * INTO v_user FROM public.users WHERE id = v_session.user_id LIMIT 1;
    IF v_user IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'User profile not found.');
    END IF;

    v_cust_name := COALESCE(v_user.full_name, v_user.name, 'Customer');
    v_cust_phone := COALESCE(v_user.mobile, v_user.phone, '');

    -- 2. Owner-Scoped Idempotency Check (Authenticated session required)
    IF p_idempotency_key IS NOT NULL AND TRIM(p_idempotency_key) <> '' THEN
        SELECT id, total, subtotal, gst, delivery_fee, coupon_discount, wallet_discount
        INTO v_existing_order
        FROM public.orders
        WHERE user_id = v_user.id AND idempotency_key = TRIM(p_idempotency_key)
        LIMIT 1;

        IF v_existing_order.id IS NOT NULL THEN
            RETURN jsonb_build_object(
                'success', true,
                'order_id', v_existing_order.id,
                'total', v_existing_order.total,
                'subtotal', v_existing_order.subtotal,
                'gst', v_existing_order.gst,
                'delivery_fee', v_existing_order.delivery_fee,
                'coupon_discount', v_existing_order.coupon_discount,
                'wallet_discount', COALESCE(v_existing_order.wallet_discount, 0.0),
                'is_duplicate_retry', true
            );
        END IF;
    END IF;

    -- 3. Validate Items & Compute Subtotal accurately against public.products
    v_items_count := jsonb_array_length(p_items);
    IF v_items_count = 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'Order cart is empty.');
    END IF;

    FOR i IN 0..(v_items_count - 1) LOOP
        v_item_data := p_items->i;
        SELECT * INTO v_product FROM public.products WHERE id = (v_item_data->>'product_id')::BIGINT LIMIT 1;
        IF v_product IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error', 'Product not found: ' || (v_item_data->>'name'));
        END IF;

        v_item_price := (v_item_data->>'price')::NUMERIC;
        v_subtotal := v_subtotal + (v_item_price * (v_item_data->>'quantity')::INTEGER);
    END LOOP;

    -- 4. Calculate Delivery Fee & Location Details (Note: column in addresses table is 'map_link')
    IF p_address_id IS NOT NULL THEN
        SELECT latitude, longitude, map_link INTO v_addr_lat, v_addr_lng, v_addr_map_link
        FROM public.addresses WHERE id = p_address_id LIMIT 1;
    END IF;

    IF p_delivery_mode = 'delivery' THEN
        IF p_road_distance_km IS NOT NULL THEN
            v_distance := p_road_distance_km;
        ELSIF v_addr_lat IS NOT NULL AND v_addr_lng IS NOT NULL THEN
            v_distance := public.calculate_distance_km(v_store_lat, v_store_lng, v_addr_lat, v_addr_lng);
        END IF;

        SELECT * INTO v_delivery_settings FROM public.delivery_settings ORDER BY id LIMIT 1;

        IF v_distance IS NULL THEN
            IF v_delivery_settings IS NOT NULL AND v_subtotal >= COALESCE(v_delivery_settings.free_delivery_above, 299) THEN
                v_delivery_fee := 0.0;
            ELSE
                v_delivery_fee := COALESCE(v_delivery_settings.delivery_charge, 40.0);
            END IF;
        ELSE
            v_slab_matched := FALSE;
            v_slab_free_above := NULL;
            v_slab_charge := 0.0;
            v_max_slab_limit := 10.0;

            IF v_delivery_settings IS NOT NULL AND v_delivery_settings.distance_slabs IS NOT NULL THEN
                FOR v_slab IN SELECT * FROM jsonb_to_recordset(v_delivery_settings.distance_slabs) AS (min NUMERIC, max NUMERIC, charge NUMERIC, free_above NUMERIC) LOOP
                    IF v_slab.max IS NOT NULL AND v_slab.max > v_max_slab_limit THEN
                        v_max_slab_limit := v_slab.max;
                    END IF;
                    IF (NOT v_slab_matched) AND v_distance >= v_slab.min AND v_distance < v_slab.max THEN
                        v_slab_charge := COALESCE(v_slab.charge, 0.0);
                        v_slab_free_above := v_slab.free_above;
                        v_slab_matched := TRUE;
                    END IF;
                END LOOP;
            END IF;

            IF (NOT v_slab_matched) OR v_distance > v_max_slab_limit THEN
                v_delivery_fee := 0.0;
            ELSIF v_slab_free_above IS NOT NULL AND v_subtotal >= v_slab_free_above THEN
                v_delivery_fee := 0.0;
            ELSE
                v_delivery_fee := v_slab_charge;
            END IF;
        END IF;
    ELSE
        v_delivery_fee := 0.0;
    END IF;

    -- 5. Calculate GST (5%)
    v_gst := ROUND(v_subtotal * 0.05, 2);

    -- 6. Validate Coupon Code (public.coupons, falling back to legacy public.offers)
    IF p_coupon_code IS NOT NULL AND p_coupon_code <> '' THEN
        v_coupon_found := FALSE;

        SELECT * INTO v_coupon FROM public.coupons WHERE code = p_coupon_code AND active = TRUE LIMIT 1;
        IF FOUND THEN
            v_coupon_found := TRUE;
        ELSE
            SELECT * INTO v_offer FROM public.offers WHERE code = p_coupon_code AND active = TRUE LIMIT 1;
            IF FOUND THEN
                v_coupon.id := v_offer.id;
                v_coupon.code := v_offer.code;
                v_coupon.discount_type := v_offer.discount_type;
                v_coupon.discount_value := COALESCE(v_offer.discount_value, 0.0);
                v_coupon.max_discount := v_offer.max_discount;
                v_coupon.min_order := COALESCE(v_offer.min_order, 0.0);
                v_coupon_found := TRUE;
            END IF;
        END IF;

        IF v_coupon_found THEN
            IF v_subtotal >= COALESCE(v_coupon.min_order, 0.0) THEN
                IF v_coupon.discount_type = 'percentage' THEN
                    v_coupon_discount := ROUND(v_subtotal * (v_coupon.discount_value / 100.0), 2);
                    IF v_coupon.max_discount IS NOT NULL AND v_coupon_discount > v_coupon.max_discount THEN
                        v_coupon_discount := v_coupon.max_discount;
                    END IF;
                ELSIF v_coupon.discount_type = 'flat' THEN
                    v_coupon_discount := v_coupon.discount_value;
                END IF;
            END IF;
        END IF;
    END IF;

    -- 7. Validate & Atomically Deduct Wallet Balance (SELECT ... FOR UPDATE)
    IF p_use_wallet = TRUE THEN
        SELECT * INTO v_wallet
        FROM public.cheesy_wallets
        WHERE user_id = v_user.id AND wallet_status = 'active'
        FOR UPDATE;

        SELECT * INTO v_wallet_settings
        FROM public.cheesy_wallet_settings
        WHERE id = 1 LIMIT 1;

        IF v_wallet IS NOT NULL AND v_wallet_settings IS NOT NULL AND v_wallet.available_coins > 0 THEN
            IF v_subtotal >= COALESCE(v_wallet_settings.min_order_value, 0) THEN
                DECLARE
                    v_max_rupee_discount NUMERIC;
                    v_coins_needed INT;
                    v_ratio NUMERIC := 1.0;
                BEGIN
                    v_ratio := COALESCE(v_wallet_settings.coin_ratio_rupees / NULLIF(v_wallet_settings.coin_ratio_coins, 0), 1.0);
                    v_max_rupee_discount := ROUND(v_subtotal * (COALESCE(v_wallet_settings.max_redeem_percent, 50) / 100.0), 2);
                    v_coins_needed := CEIL(v_max_rupee_discount / v_ratio);

                    v_wallet_redeem_coins := LEAST(v_wallet.available_coins, v_coins_needed);
                    v_wallet_redeem_rupees := ROUND(v_wallet_redeem_coins * v_ratio, 2);
                END;
            END IF;
        END IF;
    END IF;

    -- 8. Calculate Final Total
    v_final_total := v_subtotal + v_gst + v_delivery_fee - v_coupon_discount - v_wallet_redeem_rupees;
    IF v_final_total < 0 THEN
        v_final_total := 0.0;
    END IF;

    -- Determine Initial Status values
    IF p_payment_method = 'COD' THEN
        v_init_payment_status := 'PAYMENT_PENDING';
        v_init_order_status := 'CONFIRMED';
        v_init_status := 'Pending';
    ELSIF v_final_total <= 0 THEN
        v_init_payment_status := 'SUCCESS';
        v_init_order_status := 'CONFIRMED';
        v_init_status := 'Pending';
    ELSE
        v_init_payment_status := 'PAYMENT_PENDING';
        v_init_order_status := 'PAYMENT_PENDING';
        v_init_status := 'PAYMENT_PENDING';
    END IF;

    -- 9. Insert Order Record securely with sub-block for concurrent unique_violation handling
    BEGIN
        INSERT INTO public.orders (
            user_id, customer_name, phone, address, landmark,
            payment_method, payment_status, order_status, subtotal, gst, delivery_fee,
            total, status, delivery_mode, coupon_code, coupon_discount,
            coins_redeemed, coins_earned, order_source,
            latitude, longitude, distance_km, google_map_link,
            road_distance_km, estimated_time_minutes, route_geometry,
            payment_gateway, payment_attempt, payment_verified, auto_retry_enabled,
            wallet_redemption_status, wallet_redemption_updated_at, idempotency_key
        ) VALUES (
            v_user.id, v_cust_name, v_cust_phone, p_address, p_landmark,
            p_payment_method, v_init_payment_status, v_init_order_status, v_subtotal, v_gst, v_delivery_fee,
            v_final_total, v_init_status, p_delivery_mode, p_coupon_code, v_coupon_discount,
            v_wallet_redeem_coins, 0, 'online',
            v_addr_lat, v_addr_lng, v_distance, v_addr_map_link,
            p_road_distance_km, p_estimated_time_minutes, p_route_geometry,
            CASE WHEN p_payment_method = 'COD' THEN 'COD' ELSE 'Razorpay' END, 0, FALSE, TRUE,
            CASE WHEN v_wallet_redeem_coins > 0 THEN 'COMPLETED' ELSE 'NONE' END, NOW(),
            NULLIF(TRIM(p_idempotency_key), '')
        ) RETURNING id INTO v_order_id;
    EXCEPTION WHEN unique_violation THEN
        IF p_idempotency_key IS NOT NULL AND TRIM(p_idempotency_key) <> '' THEN
            SELECT id, total, subtotal, gst, delivery_fee, coupon_discount, wallet_discount
            INTO v_existing_order
            FROM public.orders
            WHERE user_id = v_user.id AND idempotency_key = TRIM(p_idempotency_key)
            LIMIT 1;

            IF v_existing_order.id IS NOT NULL THEN
                RETURN jsonb_build_object(
                    'success', true,
                    'order_id', v_existing_order.id,
                    'total', v_existing_order.total,
                    'subtotal', v_existing_order.subtotal,
                    'gst', v_existing_order.gst,
                    'delivery_fee', v_existing_order.delivery_fee,
                    'coupon_discount', v_existing_order.coupon_discount,
                    'wallet_discount', COALESCE(v_existing_order.wallet_discount, 0.0),
                    'is_duplicate_retry', true
                );
            END IF;
        END IF;
        RAISE;
    END;

    -- 10. Atomically Deduct Wallet Balance & Log Transaction inside the same DB Transaction
    IF v_wallet_redeem_coins > 0 THEN
        UPDATE public.cheesy_wallets
        SET available_coins = GREATEST(0, available_coins - v_wallet_redeem_coins),
            lifetime_redeemed = lifetime_redeemed + v_wallet_redeem_coins,
            updated_at = NOW()
        WHERE user_id = v_user.id;

        INSERT INTO public.cheesy_wallet_transactions (
            user_id, transaction_type, coins, rupee_value, reference_type, reference_id, remarks
        ) VALUES (
            v_user.id, 'redeem', -v_wallet_redeem_coins, -v_wallet_redeem_rupees, 'order', v_order_id::text, 'Redeemed on Order #' || v_order_id
        );
    END IF;

    -- Update last_used_at timestamp on saved address if relevant
    IF p_address_id IS NOT NULL THEN
        UPDATE public.addresses SET last_used_at = NOW() WHERE id = p_address_id;
    END IF;

    -- 11. Insert Order Items Records into public.order_items (canonical schema: product_name, price, quantity, variant_name, addons)
    FOR i IN 0..(v_items_count - 1) LOOP
        v_item_data := p_items->i;
        v_item_price := (v_item_data->>'price')::NUMERIC;
        v_variant_name := COALESCE(v_item_data->'variant'->>'name', '');
        v_addons_names := '';

        IF jsonb_typeof(v_item_data->'addons') = 'array' AND jsonb_array_length(v_item_data->'addons') > 0 THEN
            DECLARE
                v_addon_names_list TEXT[] := ARRAY[]::TEXT[];
            BEGIN
                FOR j IN 0..(jsonb_array_length(v_item_data->'addons') - 1) LOOP
                    v_addon_names_list := array_append(v_addon_names_list, (v_item_data->'addons'->j->>'name')::TEXT);
                END LOOP;
                v_addons_names := array_to_string(v_addon_names_list, ', ');
            END;
        END IF;

        INSERT INTO public.order_items (
            order_id, product_id, product_name, price, quantity, variant_name, addons
        ) VALUES (
            v_order_id,
            (v_item_data->>'product_id')::BIGINT,
            v_item_data->>'name',
            v_item_price,
            (v_item_data->>'quantity')::INTEGER,
            v_variant_name,
            CASE WHEN v_addons_names = '' THEN NULL ELSE v_addons_names END
        ) RETURNING id INTO v_order_item_id;
    END LOOP;

    RETURN jsonb_build_object(
        'success', true,
        'order_id', v_order_id,
        'total', v_final_total,
        'subtotal', v_subtotal,
        'gst', v_gst,
        'delivery_fee', v_delivery_fee,
        'coupon_discount', v_coupon_discount,
        'wallet_discount', v_wallet_redeem_rupees
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.secure_update_pos_customer_name(
    p_session_token TEXT,
    p_phone TEXT,
    p_name TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_clean_phone TEXT;
    v_clean_name TEXT;
    v_placeholders CONSTANT TEXT[] := ARRAY[
        'pos customer', 'customer', 'walk-in guest', 'walk-in customer', 'walk-in', 'guest', 'unknown'
    ];
BEGIN
    -- 1. Validate session token
    IF p_session_token IS NULL OR TRIM(p_session_token) = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'EMPTY_TOKEN');
    END IF;

    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF v_auth.is_valid IS NOT TRUE THEN
        RETURN jsonb_build_object('success', false, 'error', COALESCE(v_auth.error_code, 'INVALID_TOKEN'));
    END IF;

    -- 2. Validate role
    IF v_auth.role IS NULL OR lower(v_auth.role) NOT IN ('super_admin', 'admin', 'manager', 'pos_staff', 'cashier', 'staff') THEN
        RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;

    -- 3. Normalize phone & trim name
    v_clean_phone := REGEXP_REPLACE(COALESCE(p_phone, ''), '\D', '', 'g');
    IF LENGTH(v_clean_phone) = 12 AND LEFT(v_clean_phone, 2) = '91' THEN
        v_clean_phone := SUBSTRING(v_clean_phone FROM 3);
    ELSIF LENGTH(v_clean_phone) = 11 AND LEFT(v_clean_phone, 1) = '0' THEN
        v_clean_phone := SUBSTRING(v_clean_phone FROM 2);
    END IF;

    v_clean_name := TRIM(COALESCE(p_name, ''));

    -- Guard against invalid phone, empty/null name, or generic placeholders
    IF v_clean_phone !~ '^[6-9][0-9]{9}$' THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_PHONE');
    END IF;

    IF v_clean_name = '' OR v_clean_name LIKE '%@%' OR LOWER(v_clean_name) = ANY(v_placeholders) THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_NAME');
    END IF;

    -- 4. Update public.customers
    INSERT INTO public.customers (name, mobile, source, created_at, updated_at)
    VALUES (v_clean_name, v_clean_phone, 'POS', NOW(), NOW())
    ON CONFLICT (mobile) DO UPDATE SET name = v_clean_name, updated_at = NOW();

    -- 5. Update public.users (both name and full_name columns if user exists)
    UPDATE public.users
    SET name = v_clean_name,
        full_name = v_clean_name,
        updated_at = NOW()
    WHERE phone = v_clean_phone OR mobile = v_clean_phone;

    RETURN jsonb_build_object(
        'success', true,
        'mobile', v_clean_phone,
        'name', v_clean_name
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_change_table_session(
    p_session_token TEXT,
    p_source_table_id BIGINT,
    p_target_table_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_auth RECORD;
    v_min_id BIGINT;
    v_max_id BIGINT;
    v_min_table RECORD;
    v_max_table RECORD;
    v_source_table RECORD;
    v_target_table RECORD;
    v_session RECORD;
    v_target_active_session_count INTEGER;
    v_updated_orders_count INTEGER := 0;
BEGIN
    -- 1. Argument validation
    IF p_session_token IS NULL OR TRIM(p_session_token) = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_TOKEN', 'message', 'Session token is required.');
    END IF;
    IF p_source_table_id IS NULL OR p_source_table_id <= 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_SOURCE_TABLE', 'message', 'Valid source table ID is required.');
    END IF;
    IF p_target_table_id IS NULL OR p_target_table_id <= 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_TARGET_TABLE', 'message', 'Valid target table ID is required.');
    END IF;
    IF p_source_table_id = p_target_table_id THEN
        RETURN jsonb_build_object('success', false, 'error', 'SAME_TABLE', 'message', 'Source and target table cannot be the same.');
    END IF;

    -- 2. Staff authorization validation
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF NOT v_auth.is_valid THEN
        RETURN jsonb_build_object('success', false, 'error', COALESCE(v_auth.error_code, 'INVALID_SESSION'), 'message', 'Session invalid or expired.');
    END IF;

    IF v_auth.role IS NULL OR lower(trim(v_auth.role)) IN ('customer', 'user', 'guest') OR lower(trim(v_auth.role)) NOT IN ('pos', 'pos_staff', 'cashier', 'staff', 'manager', 'admin', 'super_admin', 'staffadmin', 'staff_admin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'UNAUTHORIZED_ROLE', 'message', 'Unauthorized role to change table.');
    END IF;

    -- 3. Lock source and target table rows in deterministic ID order to prevent deadlocks
    v_min_id := LEAST(p_source_table_id, p_target_table_id);
    v_max_id := GREATEST(p_source_table_id, p_target_table_id);

    SELECT * INTO v_min_table FROM public.pos_tables WHERE id = v_min_id FOR UPDATE;
    SELECT * INTO v_max_table FROM public.pos_tables WHERE id = v_max_id FOR UPDATE;

    IF p_source_table_id = v_min_id THEN
        v_source_table := v_min_table;
        v_target_table := v_max_table;
    ELSE
        v_source_table := v_max_table;
        v_target_table := v_min_table;
    END IF;

    -- 4. Confirm table existence
    IF v_source_table.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'SOURCE_TABLE_NOT_FOUND', 'message', 'Source table does not exist.');
    END IF;
    IF v_target_table.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'TARGET_TABLE_NOT_FOUND', 'message', 'Target table does not exist.');
    END IF;

    -- 5. Validate source table state (must actually have a running order/session)
    IF lower(COALESCE(v_source_table.status, '')) = 'available' OR (
        (v_source_table.active_order_id IS NULL OR TRIM(v_source_table.active_order_id) = '') AND
        v_source_table.active_session_id IS NULL
    ) THEN
        RETURN jsonb_build_object('success', false, 'error', 'SOURCE_STATE_CHANGED', 'message', 'Source table does not have an active running order or session.');
    END IF;

    -- 6. Validate target table availability (must be available with no active order/session pointer)
    IF lower(COALESCE(v_target_table.status, '')) <> 'available' OR
       (v_target_table.active_order_id IS NOT NULL AND TRIM(v_target_table.active_order_id) <> '') OR
       v_target_table.active_session_id IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'TABLE_OCCUPIED_CONFLICT', 'message', 'Target table is occupied or unavailable.');
    END IF;

    -- 7. Check for stale active table_session on target table
    SELECT COUNT(*)::integer INTO v_target_active_session_count
    FROM public.table_sessions
    WHERE table_id = p_target_table_id AND lower(COALESCE(status, '')) = 'active';

    IF v_target_active_session_count > 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'TARGET_STATE_CONFLICT', 'message', 'Target table has an active session record in database.');
    END IF;

    -- 8. Identify active session on source table
    IF v_source_table.active_session_id IS NOT NULL THEN
        SELECT * INTO v_session FROM public.table_sessions WHERE id = v_source_table.active_session_id FOR UPDATE;
    END IF;

    IF v_session.id IS NULL THEN
        SELECT * INTO v_session
        FROM public.table_sessions
        WHERE table_id = p_source_table_id AND lower(COALESCE(status, '')) = 'active'
        ORDER BY id DESC
        LIMIT 1
        FOR UPDATE;
    END IF;

    -- 9. Update existing table_session table_id if present
    IF v_session.id IS NOT NULL THEN
        UPDATE public.table_sessions
        SET table_id = p_target_table_id
        WHERE id = v_session.id;
    END IF;

    -- 10. Move open pos_orders from source table to target table
    UPDATE public.pos_orders
    SET table_id = p_target_table_id,
        updated_at = NOW()
    WHERE lower(COALESCE(status, '')) NOT IN ('completed', 'cancelled', 'voided', 'rejected', 'closed', 'settled', 'picked up', 'delivered')
      AND (
        table_id = p_source_table_id
        OR (v_session.id IS NOT NULL AND table_session_id = v_session.id)
      );

    GET DIAGNOSTICS v_updated_orders_count = ROW_COUNT;

    -- 11. Occupy Target Table in pos_tables
    UPDATE public.pos_tables
    SET status = COALESCE(v_source_table.status, 'occupied'),
        guests = COALESCE(v_source_table.guests, 4),
        active_order_id = v_source_table.active_order_id,
        active_session_id = COALESCE(v_session.id, v_source_table.active_session_id),
        updated_at = NOW()
    WHERE id = p_target_table_id;

    -- 12. Release Source Table in pos_tables
    UPDATE public.pos_tables
    SET status = 'available',
        guests = 0,
        active_order_id = NULL,
        active_session_id = NULL,
        updated_at = NOW()
    WHERE id = p_source_table_id;

    -- 13. Return success payload
    RETURN jsonb_build_object(
        'success', true,
        'source_table_id', p_source_table_id,
        'target_table_id', p_target_table_id,
        'target_table_name', v_target_table.name,
        'active_order_id', v_source_table.active_order_id,
        'active_session_id', COALESCE(v_session.id, v_source_table.active_session_id),
        'session_token', v_session.session_token,
        'orders_updated_count', v_updated_orders_count
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_get_pos_orders_report_admin(
    p_session_token TEXT,
    p_from TIMESTAMPTZ DEFAULT NULL,
    p_to TIMESTAMPTZ DEFAULT NULL,
    p_before_id BIGINT DEFAULT NULL,
    p_limit INTEGER DEFAULT 2000
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_limit INTEGER;
    v_rows JSONB;
    v_count INTEGER;
    v_min_id BIGINT;
BEGIN
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF v_auth.is_valid IS NOT TRUE THEN
        RETURN jsonb_build_object('success', false, 'error', COALESCE(v_auth.error_code, 'UNAUTHORIZED'));
    END IF;
    IF lower(COALESCE(v_auth.role, '')) NOT IN ('admin', 'manager', 'super_admin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;

    v_limit := LEAST(GREATEST(COALESCE(p_limit, 2000), 1), 5000);

    SELECT
        COALESCE(jsonb_agg(
            jsonb_build_object(
                'id', po.id,
                'order_number', po.order_number,
                'created_at', po.created_at,
                'updated_at', po.updated_at,
                'business_date', po.business_date,
                'status', po.status,
                'payment_status', po.payment_status,
                'payment_method', po.payment_method,
                'subtotal', po.subtotal,
                'gst', po.gst,
                'delivery_fee', po.delivery_fee,
                'total', po.total,
                'delivery_mode', po.delivery_mode,
                'order_source', po.order_source,
                'customer_name', po.customer_name,
                'phone', po.phone,
                'address', po.address,
                'landmark', po.landmark,
                'table_id', po.table_id,
                'table_session_id', po.table_session_id,
                'offline_sync_id', po.offline_sync_id,
                'coupon_code', po.coupon_code,
                'coupon_discount', po.coupon_discount,
                'manual_discount_type', po.manual_discount_type,
                'manual_discount_value', po.manual_discount_value,
                'manual_discount_amount', po.manual_discount_amount,
                'manual_discount_percent', po.manual_discount_percent,
                'service_charge_type', po.service_charge_type,
                'service_charge_value', po.service_charge_value,
                'service_charge_amount', po.service_charge_amount,
                'coins_redeemed', po.coins_redeemed,
                'wallet_discount', po.wallet_discount,
                'rejection_reason', po.rejection_reason,
                'notes', po.notes
            ) ORDER BY po.id DESC
        ), '[]'::jsonb),
        COUNT(*),
        MIN(po.id)
    INTO v_rows, v_count, v_min_id
    FROM (
        SELECT *
        FROM public.pos_orders
        WHERE (p_from IS NULL OR created_at >= p_from)
          AND (p_to IS NULL OR created_at <= p_to)
          AND (p_before_id IS NULL OR id < p_before_id)
        ORDER BY id DESC
        LIMIT v_limit
    ) po;

    RETURN jsonb_build_object(
        'success', true,
        'orders', v_rows,
        'has_more', v_count = v_limit,
        'next_before_id', v_min_id
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_get_pos_order_items_report_admin(
    p_session_token TEXT,
    p_from TIMESTAMPTZ DEFAULT NULL,
    p_to TIMESTAMPTZ DEFAULT NULL,
    p_after_id BIGINT DEFAULT NULL,
    p_limit INTEGER DEFAULT 5000
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_limit INTEGER;
    v_rows JSONB;
    v_count INTEGER;
    v_max_id BIGINT;
BEGIN
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF v_auth.is_valid IS NOT TRUE THEN
        RETURN jsonb_build_object('success', false, 'error', COALESCE(v_auth.error_code, 'UNAUTHORIZED'));
    END IF;
    IF lower(COALESCE(v_auth.role, '')) NOT IN ('admin', 'manager', 'super_admin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;

    v_limit := LEAST(GREATEST(COALESCE(p_limit, 5000), 1), 5000);

    SELECT
        COALESCE(jsonb_agg(
            jsonb_build_object(
                'id', poi.id,
                'order_id', poi.order_id,
                'session_item_id', poi.session_item_id,
                'product_id', poi.product_id,
                'product_name', poi.product_name,
                'variant_name', poi.variant_name,
                'addons', poi.addons,
                'quantity', poi.quantity,
                'price', poi.price,
                'total', poi.total,
                'status', poi.status,
                'item_discount_amount', poi.item_discount_amount,
                'item_final_price', poi.item_final_price
            ) ORDER BY poi.id ASC
        ), '[]'::jsonb),
        COUNT(*),
        MAX(poi.id)
    INTO v_rows, v_count, v_max_id
    FROM (
        SELECT i.*
        FROM public.pos_order_items i
        JOIN public.pos_orders o ON o.id = i.order_id
        WHERE (p_from IS NULL OR o.created_at >= p_from)
          AND (p_to IS NULL OR o.created_at <= p_to)
          AND (p_after_id IS NULL OR i.id > p_after_id)
        ORDER BY i.id ASC
        LIMIT v_limit
    ) poi;

    RETURN jsonb_build_object(
        'success', true,
        'items', v_rows,
        'has_more', v_count = v_limit,
        'next_after_id', v_max_id
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_get_website_orders_report_admin(
    p_session_token TEXT,
    p_from TIMESTAMPTZ DEFAULT NULL,
    p_to TIMESTAMPTZ DEFAULT NULL,
    p_before_id BIGINT DEFAULT NULL,
    p_limit INTEGER DEFAULT 2000
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_limit INTEGER;
    v_rows JSONB;
    v_count INTEGER;
    v_min_id BIGINT;
BEGIN
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF v_auth.is_valid IS NOT TRUE THEN
        RETURN jsonb_build_object('success', false, 'error', COALESCE(v_auth.error_code, 'UNAUTHORIZED'));
    END IF;
    IF lower(COALESCE(v_auth.role, '')) NOT IN ('admin', 'manager', 'super_admin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;

    v_limit := LEAST(GREATEST(COALESCE(p_limit, 2000), 1), 5000);

    SELECT
        COALESCE(jsonb_agg(
            jsonb_build_object(
                'id', wo.id,
                'created_at', wo.created_at,
                'status', wo.status,
                'order_status', wo.order_status,
                'payment_status', wo.payment_status,
                'payment_method', wo.payment_method,
                'razorpay_payment_id', wo.razorpay_payment_id,
                'subtotal', wo.subtotal,
                'gst', wo.gst,
                'delivery_fee', wo.delivery_fee,
                'total', wo.total,
                'delivery_mode', wo.delivery_mode,
                'order_source', wo.order_source,
                'customer_name', wo.customer_name,
                'phone', wo.phone,
                'address', wo.address,
                'landmark', wo.landmark,
                'coupon_code', wo.coupon_code,
                'coupon_discount', wo.coupon_discount,
                'coins_redeemed', wo.coins_redeemed,
                'wallet_discount', wo.wallet_discount,
                'cancel_reason', wo.cancel_reason,
                'cancelled_at', wo.cancelled_at,
                'completed_at', wo.completed_at,
                'delivered_at', wo.delivered_at
            ) ORDER BY wo.id DESC
        ), '[]'::jsonb),
        COUNT(*),
        MIN(wo.id)
    INTO v_rows, v_count, v_min_id
    FROM (
        SELECT *
        FROM public.orders
        WHERE (p_from IS NULL OR created_at >= p_from)
          AND (p_to IS NULL OR created_at <= p_to)
          AND (p_before_id IS NULL OR id < p_before_id)
        ORDER BY id DESC
        LIMIT v_limit
    ) wo;

    RETURN jsonb_build_object(
        'success', true,
        'orders', v_rows,
        'has_more', v_count = v_limit,
        'next_before_id', v_min_id
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_get_website_order_items_report_admin(
    p_session_token TEXT,
    p_from TIMESTAMPTZ DEFAULT NULL,
    p_to TIMESTAMPTZ DEFAULT NULL,
    p_after_id BIGINT DEFAULT NULL,
    p_limit INTEGER DEFAULT 5000
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_limit INTEGER;
    v_rows JSONB;
    v_count INTEGER;
    v_max_id BIGINT;
BEGIN
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF v_auth.is_valid IS NOT TRUE THEN
        RETURN jsonb_build_object('success', false, 'error', COALESCE(v_auth.error_code, 'UNAUTHORIZED'));
    END IF;
    IF lower(COALESCE(v_auth.role, '')) NOT IN ('admin', 'manager', 'super_admin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;

    v_limit := LEAST(GREATEST(COALESCE(p_limit, 5000), 1), 5000);

    SELECT
        COALESCE(jsonb_agg(
            jsonb_build_object(
                'id', woi.id,
                'order_id', woi.order_id,
                'product_id', woi.product_id,
                'product_name', woi.product_name,
                'variant_name', woi.variant_name,
                'addons', woi.addons,
                'quantity', woi.quantity,
                'price', woi.price
            ) ORDER BY woi.id ASC
        ), '[]'::jsonb),
        COUNT(*),
        MAX(woi.id)
    INTO v_rows, v_count, v_max_id
    FROM (
        SELECT i.*
        FROM public.order_items i
        JOIN public.orders o ON o.id = i.order_id
        WHERE (p_from IS NULL OR o.created_at >= p_from)
          AND (p_to IS NULL OR o.created_at <= p_to)
          AND (p_after_id IS NULL OR i.id > p_after_id)
        ORDER BY i.id ASC
        LIMIT v_limit
    ) woi;

    RETURN jsonb_build_object(
        'success', true,
        'items', v_rows,
        'has_more', v_count = v_limit,
        'next_after_id', v_max_id
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_get_active_pos_order_item_signatures(
    p_session_token TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_rows JSONB;
BEGIN
    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF v_auth.is_valid IS NOT TRUE THEN
        RETURN jsonb_build_object('success', false, 'error', COALESCE(v_auth.error_code, 'UNAUTHORIZED'));
    END IF;

    IF lower(COALESCE(v_auth.role, '')) NOT IN ('admin', 'manager', 'cashier', 'kitchen', 'staff', 'pos_staff', 'super_admin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;

    WITH active_tables AS (
        SELECT t.id AS table_id, t.active_session_id, NULLIF(TRIM(t.active_order_id), '') AS active_order_id
        FROM public.pos_tables t
        WHERE t.active_session_id IS NOT NULL
           OR NULLIF(TRIM(t.active_order_id), '') IS NOT NULL
    ),
    linked_orders AS (
        -- UNION (not OR) so each branch can use its own access path:
        -- session pointer, offline_sync_id unique index, primary key.
        SELECT o.id
        FROM active_tables a
        JOIN public.pos_orders o ON o.table_session_id = a.active_session_id
        WHERE a.active_session_id IS NOT NULL
        UNION
        SELECT o.id
        FROM active_tables a
        JOIN public.pos_orders o ON o.offline_sync_id = a.active_order_id
        WHERE a.active_order_id IS NOT NULL
        UNION
        SELECT o.id
        FROM active_tables a
        JOIN public.pos_orders o
          ON o.id = (CASE WHEN a.active_order_id ~ '^\d+$' THEN a.active_order_id::BIGINT END)
        WHERE a.active_order_id IS NOT NULL
    ),
    active_orders AS (
        SELECT o.id, o.table_id, o.table_session_id
        FROM linked_orders l
        JOIN public.pos_orders o ON o.id = l.id
        WHERE o.status IS NOT NULL
          AND upper(trim(o.status)) NOT IN (
              'CLOSED', 'VOIDED', 'REFUNDED', 'CANCELLED', 'COMPLETED', 'SETTLED', 'PAID',
              'ARCHIVED', 'VOID', 'DELETED', 'REJECTED', 'PICKED_UP', 'PICKED UP', 'DELIVERED'
          )
    ),
    signatures AS (
        SELECT
            ao.id AS order_id,
            ao.table_id,
            ao.table_session_id,
            COUNT(poi.id) AS item_count,
            COALESCE(SUM(poi.quantity), 0) AS quantity_sum,
            COALESCE(SUM(poi.total), 0) AS item_total_sum,
            MAX(poi.id) AS max_item_id,
            md5(
                'v1|' || COALESCE(
                    string_agg(
                        jsonb_build_array(
                            poi.id,
                            poi.session_item_id,
                            poi.product_id,
                            poi.product_name,
                            poi.product_image,
                            poi.variant_name,
                            to_jsonb(poi.addons),
                            poi.quantity,
                            poi.price,
                            poi.total,
                            poi.item_discount_type,
                            poi.item_discount_value,
                            poi.item_discount_amount,
                            poi.item_discount_reason,
                            poi.item_final_price,
                            poi.status,
                            poi.rejection_reason,
                            poi.is_modified,
                            poi.modified_reason,
                            to_jsonb(poi.combo_snapshot)
                        )::text,
                        ',' ORDER BY poi.id
                    ) FILTER (WHERE poi.id IS NOT NULL),
                    ''
                )
            ) AS item_signature
        FROM active_orders ao
        LEFT JOIN public.pos_order_items poi ON poi.order_id = ao.id
        GROUP BY ao.id, ao.table_id, ao.table_session_id
    )
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'order_id', s.order_id,
            'table_id', s.table_id,
            'table_session_id', s.table_session_id,
            'item_signature', s.item_signature,
            'item_count', s.item_count,
            'quantity_sum', s.quantity_sum,
            'item_total_sum', s.item_total_sum,
            'max_item_id', s.max_item_id
        ) ORDER BY s.order_id
    ), '[]'::jsonb)
    INTO v_rows
    FROM signatures s;

    RETURN jsonb_build_object('success', true, 'signatures', v_rows);
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_save_category(
    p_session_token TEXT,
    p_payload JSONB DEFAULT '{}'::jsonb
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_target_id BIGINT;
    v_name TEXT;
    v_image TEXT;
    v_offers_applicable BOOLEAN;
    v_upsell_eligible BOOLEAN;
    v_gst_inclusive BOOLEAN;
    v_sort_order INTEGER;
    v_result RECORD;
    v_actual_payload JSONB;
BEGIN
    IF p_session_token IS NULL OR TRIM(p_session_token) = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'UNAUTHORIZED', 'message', 'Session token is required.');
    END IF;

    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF NOT v_auth.is_valid THEN
        RETURN jsonb_build_object('success', false, 'error', COALESCE(v_auth.error_code, 'UNAUTHORIZED'));
    END IF;

    IF LOWER(TRIM(v_auth.role)) NOT IN ('super_admin', 'admin', 'manager', 'cashier', 'staff') THEN
        RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED', 'message', 'Insufficient permissions.');
    END IF;

    v_actual_payload := COALESCE(p_payload, '{}'::jsonb);

    IF v_actual_payload->>'id' IS NOT NULL AND TRIM(v_actual_payload->>'id') != '' THEN
        IF v_actual_payload->>'id' !~ '^[0-9]+$' THEN
            RETURN jsonb_build_object('success', false, 'error', 'INVALID_INPUT', 'message', 'Invalid category ID format.');
        END IF;
        v_target_id := (v_actual_payload->>'id')::BIGINT;
    ELSE
        v_target_id := NULL;
    END IF;

    v_name := TRIM(v_actual_payload->>'name');

    IF v_target_id IS NOT NULL THEN
        -- UPDATE PATH: Only update fields explicitly present in payload to prevent data regression
        IF (v_actual_payload ? 'name') AND (v_name IS NULL OR v_name = '') THEN
            RETURN jsonb_build_object('success', false, 'error', 'INVALID_INPUT', 'message', 'Category name cannot be empty.');
        END IF;

        UPDATE public.categories
        SET
            name = CASE WHEN v_actual_payload ? 'name' THEN v_name ELSE name END,
            image = CASE WHEN v_actual_payload ? 'image' THEN v_actual_payload->>'image' ELSE image END,
            offers_applicable = CASE WHEN v_actual_payload ? 'offers_applicable' THEN COALESCE((v_actual_payload->>'offers_applicable')::BOOLEAN, offers_applicable) ELSE offers_applicable END,
            upsell_eligible = CASE WHEN v_actual_payload ? 'upsell_eligible' THEN COALESCE((v_actual_payload->>'upsell_eligible')::BOOLEAN, upsell_eligible) ELSE upsell_eligible END,
            gst_inclusive = CASE WHEN v_actual_payload ? 'gst_inclusive' THEN COALESCE((v_actual_payload->>'gst_inclusive')::BOOLEAN, gst_inclusive) ELSE gst_inclusive END,
            sort_order = CASE WHEN v_actual_payload ? 'sort_order' THEN (CASE WHEN v_actual_payload->>'sort_order' IS NULL OR TRIM(v_actual_payload->>'sort_order') = '' THEN NULL WHEN v_actual_payload->>'sort_order' ~ '^-?[0-9]+$' THEN (v_actual_payload->>'sort_order')::INTEGER ELSE sort_order END) ELSE sort_order END
        WHERE id = v_target_id
        RETURNING * INTO v_result;

        IF NOT FOUND THEN
            RETURN jsonb_build_object('success', false, 'error', 'NOT_FOUND', 'message', 'Category not found for update.');
        END IF;
    ELSE
        -- CREATE PATH: Retain intended defaults for new category records
        IF v_name IS NULL OR v_name = '' THEN
            RETURN jsonb_build_object('success', false, 'error', 'INVALID_INPUT', 'message', 'Category name is required.');
        END IF;

        v_image := v_actual_payload->>'image';
        v_offers_applicable := COALESCE((v_actual_payload->>'offers_applicable')::BOOLEAN, true);
        v_upsell_eligible := COALESCE((v_actual_payload->>'upsell_eligible')::BOOLEAN, true);
        v_gst_inclusive := COALESCE((v_actual_payload->>'gst_inclusive')::BOOLEAN, false);

        IF v_actual_payload->>'sort_order' IS NOT NULL AND TRIM(v_actual_payload->>'sort_order') != '' AND v_actual_payload->>'sort_order' ~ '^-?[0-9]+$' THEN
            v_sort_order := (v_actual_payload->>'sort_order')::INTEGER;
        ELSE
            v_sort_order := 999;
        END IF;

        INSERT INTO public.categories (
            name, image, offers_applicable, upsell_eligible, gst_inclusive, sort_order
        ) VALUES (
            v_name, v_image, v_offers_applicable, v_upsell_eligible, v_gst_inclusive, v_sort_order
        )
        RETURNING * INTO v_result;
    END IF;

    RETURN jsonb_build_object('success', true, 'category', to_jsonb(v_result));
END;
$$;

CREATE OR REPLACE FUNCTION public.secure_save_product(
    p_session_token TEXT,
    p_payload JSONB DEFAULT '{}'::jsonb
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
    v_auth RECORD;
    v_target_id BIGINT;
    v_name TEXT;
    v_category TEXT;
    v_category_id BIGINT;
    v_description TEXT;
    v_price NUMERIC;
    v_image TEXT;
    v_stock BOOLEAN;
    v_status BOOLEAN;
    v_best_seller BOOLEAN;
    v_product_type TEXT;
    v_brand TEXT;
    v_sub_category TEXT;
    v_sub_category_id BIGINT;
    v_full_description TEXT;
    v_gallery_images JSONB;
    v_dietary_type TEXT;
    v_recommended BOOLEAN;
    v_new_launch BOOLEAN;
    v_featured BOOLEAN;
    v_featured_order INTEGER;
    v_chef_recommended BOOLEAN;
    v_seasonal BOOLEAN;
    v_sku TEXT;
    v_slug TEXT;
    v_spice_level TEXT;
    v_prep_time INTEGER;
    v_ingredients TEXT;
    v_allergen_info TEXT;
    v_calories INTEGER;
    v_serving_size TEXT;
    v_sales_channels JSONB;
    v_availability JSONB;
    v_manage_stock BOOLEAN;
    v_opening_stock NUMERIC;
    v_current_stock NUMERIC;
    v_low_stock_alert NUMERIC;
    v_auto_disable_stock BOOLEAN;
    v_gst_slab NUMERIC;
    v_hsn TEXT;
    v_inventory_unit TEXT;
    v_seo JSONB;
    v_sort_order INTEGER;
    v_created_by TEXT;
    v_updated_by TEXT;
    v_result RECORD;
    v_actual_payload JSONB;
BEGIN
    IF p_session_token IS NULL OR TRIM(p_session_token) = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'UNAUTHORIZED', 'message', 'Session token is required.');
    END IF;

    SELECT * INTO v_auth FROM public.validate_active_session_internal(p_session_token);
    IF NOT v_auth.is_valid THEN
        RETURN jsonb_build_object('success', false, 'error', COALESCE(v_auth.error_code, 'UNAUTHORIZED'));
    END IF;

    IF LOWER(TRIM(v_auth.role)) NOT IN ('super_admin', 'admin', 'manager', 'cashier', 'staff') THEN
        RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED', 'message', 'Insufficient permissions.');
    END IF;

    v_actual_payload := COALESCE(p_payload, '{}'::jsonb);

    v_name := TRIM(v_actual_payload->>'name');
    
    SELECT COALESCE(full_name, employee_code, v_auth.role, 'Admin')
      INTO v_updated_by
      FROM public.users
     WHERE id = v_auth.user_id;
    v_updated_by := COALESCE(NULLIF(TRIM(v_updated_by), ''), v_auth.role, 'Admin');

    IF v_actual_payload->>'id' IS NOT NULL AND TRIM(v_actual_payload->>'id') != '' THEN
        IF v_actual_payload->>'id' !~ '^[0-9]+$' THEN
            RETURN jsonb_build_object('success', false, 'error', 'INVALID_INPUT', 'message', 'Invalid product ID format.');
        END IF;
        v_target_id := (v_actual_payload->>'id')::BIGINT;
    ELSE
        v_target_id := NULL;
    END IF;

    IF v_target_id IS NOT NULL THEN
        -- UPDATE PATH: Explicit key presence check preserves existing column values when keys are absent
        IF (v_actual_payload ? 'name') AND (v_name IS NULL OR v_name = '') THEN
            RETURN jsonb_build_object('success', false, 'error', 'INVALID_INPUT', 'message', 'Product name cannot be empty.');
        END IF;

        UPDATE public.products
        SET
            name = CASE WHEN v_actual_payload ? 'name' THEN v_name ELSE name END,
            category = CASE WHEN v_actual_payload ? 'category' THEN v_actual_payload->>'category' ELSE category END,
            category_id = CASE WHEN v_actual_payload ? 'category_id' THEN (CASE WHEN v_actual_payload->>'category_id' IS NULL OR TRIM(v_actual_payload->>'category_id') = '' THEN NULL WHEN v_actual_payload->>'category_id' ~ '^[0-9]+$' THEN (v_actual_payload->>'category_id')::BIGINT ELSE category_id END) ELSE category_id END,
            description = CASE WHEN v_actual_payload ? 'description' THEN v_actual_payload->>'description' ELSE description END,
            price = CASE WHEN v_actual_payload ? 'price' THEN (CASE WHEN v_actual_payload->>'price' IS NULL OR TRIM(v_actual_payload->>'price') = '' THEN NULL WHEN v_actual_payload->>'price' ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (v_actual_payload->>'price')::NUMERIC ELSE price END) ELSE price END,
            image = CASE WHEN v_actual_payload ? 'image' THEN v_actual_payload->>'image' ELSE image END,
            stock = CASE WHEN v_actual_payload ? 'stock' THEN COALESCE((v_actual_payload->>'stock')::BOOLEAN, stock) ELSE stock END,
            status = CASE WHEN v_actual_payload ? 'status' THEN COALESCE((v_actual_payload->>'status')::BOOLEAN, status) ELSE status END,
            best_seller = CASE WHEN v_actual_payload ? 'best_seller' THEN COALESCE((v_actual_payload->>'best_seller')::BOOLEAN, best_seller) ELSE best_seller END,
            product_type = CASE WHEN v_actual_payload ? 'product_type' THEN v_actual_payload->>'product_type' ELSE product_type END,
            brand = CASE WHEN v_actual_payload ? 'brand' THEN v_actual_payload->>'brand' ELSE brand END,
            sub_category = CASE WHEN v_actual_payload ? 'sub_category' THEN v_actual_payload->>'sub_category' ELSE sub_category END,
            sub_category_id = CASE WHEN v_actual_payload ? 'sub_category_id' THEN (CASE WHEN v_actual_payload->>'sub_category_id' IS NULL OR TRIM(v_actual_payload->>'sub_category_id') = '' THEN NULL WHEN v_actual_payload->>'sub_category_id' ~ '^[0-9]+$' THEN (v_actual_payload->>'sub_category_id')::BIGINT ELSE sub_category_id END) ELSE sub_category_id END,
            full_description = CASE WHEN v_actual_payload ? 'full_description' THEN v_actual_payload->>'full_description' ELSE full_description END,
            gallery_images = CASE WHEN v_actual_payload ? 'gallery_images' THEN v_actual_payload->'gallery_images' ELSE gallery_images END,
            dietary_type = CASE WHEN v_actual_payload ? 'dietary_type' THEN v_actual_payload->>'dietary_type' ELSE dietary_type END,
            recommended = CASE WHEN v_actual_payload ? 'recommended' THEN COALESCE((v_actual_payload->>'recommended')::BOOLEAN, recommended) ELSE recommended END,
            new_launch = CASE WHEN v_actual_payload ? 'new_launch' THEN COALESCE((v_actual_payload->>'new_launch')::BOOLEAN, new_launch) ELSE new_launch END,
            featured = CASE WHEN v_actual_payload ? 'featured' THEN COALESCE((v_actual_payload->>'featured')::BOOLEAN, featured) ELSE featured END,
            featured_order = CASE WHEN v_actual_payload ? 'featured_order' THEN (CASE WHEN v_actual_payload->>'featured_order' IS NULL OR TRIM(v_actual_payload->>'featured_order') = '' THEN NULL WHEN v_actual_payload->>'featured_order' ~ '^-?[0-9]+$' THEN (v_actual_payload->>'featured_order')::INTEGER ELSE featured_order END) ELSE featured_order END,
            chef_recommended = CASE WHEN v_actual_payload ? 'chef_recommended' THEN COALESCE((v_actual_payload->>'chef_recommended')::BOOLEAN, chef_recommended) ELSE chef_recommended END,
            seasonal = CASE WHEN v_actual_payload ? 'seasonal' THEN COALESCE((v_actual_payload->>'seasonal')::BOOLEAN, seasonal) ELSE seasonal END,
            sku = CASE WHEN v_actual_payload ? 'sku' THEN v_actual_payload->>'sku' ELSE sku END,
            slug = CASE WHEN v_actual_payload ? 'slug' THEN v_actual_payload->>'slug' ELSE slug END,
            spice_level = CASE WHEN v_actual_payload ? 'spice_level' THEN v_actual_payload->>'spice_level' ELSE spice_level END,
            prep_time = CASE WHEN v_actual_payload ? 'prep_time' THEN (CASE WHEN v_actual_payload->>'prep_time' IS NULL OR TRIM(v_actual_payload->>'prep_time') = '' THEN NULL WHEN v_actual_payload->>'prep_time' ~ '^-?[0-9]+$' THEN (v_actual_payload->>'prep_time')::INTEGER ELSE prep_time END) ELSE prep_time END,
            ingredients = CASE WHEN v_actual_payload ? 'ingredients' THEN v_actual_payload->>'ingredients' ELSE ingredients END,
            allergen_info = CASE WHEN v_actual_payload ? 'allergen_info' THEN v_actual_payload->>'allergen_info' ELSE allergen_info END,
            calories = CASE WHEN v_actual_payload ? 'calories' THEN (CASE WHEN v_actual_payload->>'calories' IS NULL OR TRIM(v_actual_payload->>'calories') = '' THEN NULL WHEN v_actual_payload->>'calories' ~ '^-?[0-9]+$' THEN (v_actual_payload->>'calories')::INTEGER ELSE calories END) ELSE calories END,
            serving_size = CASE WHEN v_actual_payload ? 'serving_size' THEN v_actual_payload->>'serving_size' ELSE serving_size END,
            sales_channels = CASE WHEN v_actual_payload ? 'sales_channels' THEN v_actual_payload->'sales_channels' ELSE sales_channels END,
            availability = CASE WHEN v_actual_payload ? 'availability' THEN v_actual_payload->'availability' ELSE availability END,
            manage_stock = CASE WHEN v_actual_payload ? 'manage_stock' THEN COALESCE((v_actual_payload->>'manage_stock')::BOOLEAN, manage_stock) ELSE manage_stock END,
            opening_stock = CASE WHEN v_actual_payload ? 'opening_stock' THEN (CASE WHEN v_actual_payload->>'opening_stock' IS NULL OR TRIM(v_actual_payload->>'opening_stock') = '' THEN NULL WHEN v_actual_payload->>'opening_stock' ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (v_actual_payload->>'opening_stock')::NUMERIC ELSE opening_stock END) ELSE opening_stock END,
            current_stock = CASE WHEN v_actual_payload ? 'current_stock' THEN (CASE WHEN v_actual_payload->>'current_stock' IS NULL OR TRIM(v_actual_payload->>'current_stock') = '' THEN NULL WHEN v_actual_payload->>'current_stock' ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (v_actual_payload->>'current_stock')::NUMERIC ELSE current_stock END) ELSE current_stock END,
            low_stock_alert = CASE WHEN v_actual_payload ? 'low_stock_alert' THEN (CASE WHEN v_actual_payload->>'low_stock_alert' IS NULL OR TRIM(v_actual_payload->>'low_stock_alert') = '' THEN NULL WHEN v_actual_payload->>'low_stock_alert' ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (v_actual_payload->>'low_stock_alert')::NUMERIC ELSE low_stock_alert END) ELSE low_stock_alert END,
            auto_disable_stock = CASE WHEN v_actual_payload ? 'auto_disable_stock' THEN COALESCE((v_actual_payload->>'auto_disable_stock')::BOOLEAN, auto_disable_stock) ELSE auto_disable_stock END,
            gst_slab = CASE WHEN v_actual_payload ? 'gst_slab' THEN (CASE WHEN v_actual_payload->>'gst_slab' IS NULL OR TRIM(v_actual_payload->>'gst_slab') = '' THEN NULL WHEN v_actual_payload->>'gst_slab' ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (v_actual_payload->>'gst_slab')::NUMERIC ELSE gst_slab END) ELSE gst_slab END,
            hsn = CASE WHEN v_actual_payload ? 'hsn' THEN v_actual_payload->>'hsn' ELSE hsn END,
            inventory_unit = CASE WHEN v_actual_payload ? 'inventory_unit' THEN v_actual_payload->>'inventory_unit' ELSE inventory_unit END,
            seo = CASE WHEN v_actual_payload ? 'seo' THEN v_actual_payload->'seo' ELSE seo END,
            sort_order = CASE WHEN v_actual_payload ? 'sort_order' THEN (CASE WHEN v_actual_payload->>'sort_order' IS NULL OR TRIM(v_actual_payload->>'sort_order') = '' THEN NULL WHEN v_actual_payload->>'sort_order' ~ '^-?[0-9]+$' THEN (v_actual_payload->>'sort_order')::INTEGER ELSE sort_order END) ELSE sort_order END,
            updated_by = v_updated_by,
            updated_at = NOW()
        WHERE id = v_target_id
        RETURNING * INTO v_result;

        IF NOT FOUND THEN
            RETURN jsonb_build_object('success', false, 'error', 'NOT_FOUND', 'message', 'Product not found for update.');
        END IF;
    ELSE
        -- CREATE PATH: Intended defaults apply for new product records
        IF v_name IS NULL OR v_name = '' THEN
            RETURN jsonb_build_object('success', false, 'error', 'INVALID_INPUT', 'message', 'Product name is required.');
        END IF;

        v_category := TRIM(v_actual_payload->>'category');

        IF v_actual_payload->>'category_id' IS NOT NULL AND TRIM(v_actual_payload->>'category_id') != '' AND v_actual_payload->>'category_id' ~ '^[0-9]+$' THEN
            v_category_id := (v_actual_payload->>'category_id')::BIGINT;
        ELSE
            v_category_id := NULL;
        END IF;

        v_description := v_actual_payload->>'description';
        IF v_actual_payload->>'price' IS NOT NULL AND TRIM(v_actual_payload->>'price') != '' AND v_actual_payload->>'price' ~ '^-?[0-9]+(\.[0-9]+)?$' THEN
            v_price := (v_actual_payload->>'price')::NUMERIC;
        ELSE
            v_price := 0;
        END IF;

        v_image := v_actual_payload->>'image';
        v_stock := COALESCE((v_actual_payload->>'stock')::BOOLEAN, true);
        v_status := COALESCE((v_actual_payload->>'status')::BOOLEAN, true);
        v_best_seller := COALESCE((v_actual_payload->>'best_seller')::BOOLEAN, false);
        v_product_type := COALESCE(v_actual_payload->>'product_type', 'regular');
        v_brand := v_actual_payload->>'brand';
        v_sub_category := v_actual_payload->>'sub_category';
        
        IF v_actual_payload->>'sub_category_id' IS NOT NULL AND TRIM(v_actual_payload->>'sub_category_id') != '' AND v_actual_payload->>'sub_category_id' ~ '^[0-9]+$' THEN
            v_sub_category_id := (v_actual_payload->>'sub_category_id')::BIGINT;
        ELSE
            v_sub_category_id := NULL;
        END IF;

        v_full_description := v_actual_payload->>'full_description';
        v_gallery_images := v_actual_payload->'gallery_images';
        v_dietary_type := COALESCE(v_actual_payload->>'dietary_type', 'veg');
        v_recommended := COALESCE((v_actual_payload->>'recommended')::BOOLEAN, false);
        v_new_launch := COALESCE((v_actual_payload->>'new_launch')::BOOLEAN, false);
        v_featured := COALESCE((v_actual_payload->>'featured')::BOOLEAN, false);
        
        IF v_actual_payload->>'featured_order' IS NOT NULL AND TRIM(v_actual_payload->>'featured_order') != '' AND v_actual_payload->>'featured_order' ~ '^-?[0-9]+$' THEN
            v_featured_order := (v_actual_payload->>'featured_order')::INTEGER;
        ELSE
            v_featured_order := 0;
        END IF;

        v_chef_recommended := COALESCE((v_actual_payload->>'chef_recommended')::BOOLEAN, false);
        v_seasonal := COALESCE((v_actual_payload->>'seasonal')::BOOLEAN, false);
        v_sku := v_actual_payload->>'sku';
        v_slug := v_actual_payload->>'slug';
        v_spice_level := v_actual_payload->>'spice_level';
        
        IF v_actual_payload->>'prep_time' IS NOT NULL AND TRIM(v_actual_payload->>'prep_time') != '' AND v_actual_payload->>'prep_time' ~ '^-?[0-9]+$' THEN
            v_prep_time := (v_actual_payload->>'prep_time')::INTEGER;
        ELSE
            v_prep_time := NULL;
        END IF;

        v_ingredients := v_actual_payload->>'ingredients';
        v_allergen_info := v_actual_payload->>'allergen_info';
        
        IF v_actual_payload->>'calories' IS NOT NULL AND TRIM(v_actual_payload->>'calories') != '' AND v_actual_payload->>'calories' ~ '^-?[0-9]+$' THEN
            v_calories := (v_actual_payload->>'calories')::INTEGER;
        ELSE
            v_calories := NULL;
        END IF;

        v_serving_size := v_actual_payload->>'serving_size';
        v_sales_channels := v_actual_payload->'sales_channels';
        v_availability := v_actual_payload->'availability';
        v_manage_stock := COALESCE((v_actual_payload->>'manage_stock')::BOOLEAN, false);
        
        IF v_actual_payload->>'opening_stock' IS NOT NULL AND TRIM(v_actual_payload->>'opening_stock') != '' AND v_actual_payload->>'opening_stock' ~ '^-?[0-9]+(\.[0-9]+)?$' THEN
            v_opening_stock := (v_actual_payload->>'opening_stock')::NUMERIC;
        ELSE
            v_opening_stock := 0;
        END IF;

        IF v_actual_payload->>'current_stock' IS NOT NULL AND TRIM(v_actual_payload->>'current_stock') != '' AND v_actual_payload->>'current_stock' ~ '^-?[0-9]+(\.[0-9]+)?$' THEN
            v_current_stock := (v_actual_payload->>'current_stock')::NUMERIC;
        ELSE
            v_current_stock := 0;
        END IF;

        IF v_actual_payload->>'low_stock_alert' IS NOT NULL AND TRIM(v_actual_payload->>'low_stock_alert') != '' AND v_actual_payload->>'low_stock_alert' ~ '^-?[0-9]+(\.[0-9]+)?$' THEN
            v_low_stock_alert := (v_actual_payload->>'low_stock_alert')::NUMERIC;
        ELSE
            v_low_stock_alert := 10;
        END IF;

        v_auto_disable_stock := COALESCE((v_actual_payload->>'auto_disable_stock')::BOOLEAN, false);
        
        IF v_actual_payload->>'gst_slab' IS NOT NULL AND TRIM(v_actual_payload->>'gst_slab') != '' AND v_actual_payload->>'gst_slab' ~ '^-?[0-9]+(\.[0-9]+)?$' THEN
            v_gst_slab := (v_actual_payload->>'gst_slab')::NUMERIC;
        ELSE
            v_gst_slab := 5.00;
        END IF;

        v_hsn := v_actual_payload->>'hsn';
        v_inventory_unit := COALESCE(v_actual_payload->>'inventory_unit', 'pcs');
        v_seo := v_actual_payload->'seo';
        
        IF v_actual_payload->>'sort_order' IS NOT NULL AND TRIM(v_actual_payload->>'sort_order') != '' AND v_actual_payload->>'sort_order' ~ '^-?[0-9]+$' THEN
            v_sort_order := (v_actual_payload->>'sort_order')::INTEGER;
        ELSE
            v_sort_order := 0;
        END IF;

        v_created_by := v_updated_by;

        INSERT INTO public.products (
            name, category, category_id, description, price, image, stock, status, best_seller,
            product_type, brand, sub_category, sub_category_id, full_description, gallery_images,
            dietary_type, recommended, new_launch, featured, featured_order, chef_recommended,
            seasonal, sku, slug, spice_level, prep_time, ingredients, allergen_info, calories,
            serving_size, sales_channels, availability, manage_stock, opening_stock, current_stock,
            low_stock_alert, auto_disable_stock, gst_slab, hsn, inventory_unit, seo, sort_order,
            created_by, updated_by, updated_at
        ) VALUES (
            v_name, v_category, v_category_id, v_description, v_price, v_image, v_stock, v_status, v_best_seller,
            v_product_type, v_brand, v_sub_category, v_sub_category_id, v_full_description, v_gallery_images,
            v_dietary_type, v_recommended, v_new_launch, v_featured, v_featured_order, v_chef_recommended,
            v_seasonal, v_sku, v_slug, v_spice_level, v_prep_time, v_ingredients, v_allergen_info, v_calories,
            v_serving_size, v_sales_channels, v_availability, v_manage_stock, v_opening_stock, v_current_stock,
            v_low_stock_alert, v_auto_disable_stock, v_gst_slab, v_hsn, v_inventory_unit, v_seo, v_sort_order,
            v_created_by, v_updated_by, NOW()
        )
        RETURNING * INTO v_result;
    END IF;

    RETURN jsonb_build_object('success', true, 'product', to_jsonb(v_result));
END;
$$;

