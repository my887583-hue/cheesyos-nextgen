-- CHEESYOS NEXTGEN BASELINE V3 CANDIDATE: SAFE MASTER SEED DATA
-- Target Project: sdbnibyzqtgpbexlznat

INSERT INTO public.attendance_settings (id, shift_start_time, grace_time_minutes, half_day_time, absent_time, min_working_hours, gps_lat, gps_lng, gps_radius_meters, unauthorized_leave_penalty_days, late_marks_for_half_day, late_marks_for_absent)
VALUES (1, '10:00:00', 15, '11:00:00', '14:00:00', 8, 26.912433, 75.787271, 100, 2, 3, 6)
ON CONFLICT (id) DO NOTHING;
INSERT INTO public.cheesy_wallet_settings (
    id, spend_amount, earn_coins, coin_ratio_coins, coin_ratio_rupees,
    max_redeem_percent, min_order_value, expiry_options,
    signup_bonus, birthday_bonus, referral_referrer_bonus, referral_new_user_bonus,
    vip_silver_spend, vip_gold_spend, vip_platinum_spend,
    vip_silver_multiplier, vip_gold_multiplier, vip_platinum_multiplier
) VALUES (
    1, 100, 5, 1, 1.0,
    50, 199, 'Never',
    50, 100, 100, 50,
    1000, 3000, 5000,
    1.0, 1.5, 2.0
) ON CONFLICT (id) DO NOTHING;
INSERT INTO public.branches (id, name, status) 
VALUES (1, 'Main Branch', 'active') 
ON CONFLICT (id) DO NOTHING;
INSERT INTO public.roles (id, name, description) VALUES
('super_admin', 'Super Admin', 'Highest administrative authority'),
('admin', 'Admin', 'Administrative user with manager controls'),
('manager', 'Manager', 'Branch operations manager'),
('staff_admin', 'Staff Admin', 'Staff schedule and task supervisor'),
('pos_staff', 'POS Staff', 'Cashier and order booking agent'),
('kitchen_staff', 'Kitchen Staff', 'Kitchen display and food preparation staff'),
('delivery_staff', 'Delivery Staff', 'Order dispatcher and rider'),
('staff', 'Staff', 'General branch employee'),
('customer', 'Customer', 'Default customer role')
ON CONFLICT (id) DO NOTHING;
INSERT INTO public.permissions (id, name, description) VALUES
('manage_security', 'Manage Security', 'Configure RLS, settings, view alerts'),
('manage_users', 'Manage Users', 'Create, update, delete user accounts'),
('manage_branches', 'Manage Branches', 'Add or modify branch outlets'),
('manage_wallet_rules', 'Manage Wallet Rules', 'Edit coins accrual and burn rules'),
('manage_coupon_rules', 'Manage Coupon Rules', 'Create and modify coupon limits'),
('manage_attendance_rules', 'Manage Attendance Rules', 'Adjust shift timings and thresholds'),
('manage_global_settings', 'Manage Global Settings', 'Modify system-wide configurations'),
('view_audit_logs', 'View Audit Logs', 'Query centralized log trail'),
('place_order', 'Place Order', 'Create sales orders'),
('update_order_status', 'Update Order Status', 'Modify order states (Pending to Delivered)'),
('check_in_out', 'Check In/Out', 'Record attendance checklists and checkins'),
('adjust_inventory', 'Adjust Inventory', 'Increase, decrease or audit item stocks')
ON CONFLICT (id) DO NOTHING;
INSERT INTO public.role_permissions (role_id, permission_id)
SELECT 'super_admin', id FROM public.permissions ON CONFLICT DO NOTHING;
INSERT INTO public.role_permissions (role_id, permission_id)
SELECT 'admin', id FROM public.permissions 
WHERE id NOT IN ('manage_security') ON CONFLICT DO NOTHING;
INSERT INTO public.role_permissions (role_id, permission_id) VALUES
('manager', 'place_order'),
('manager', 'update_order_status'),
('manager', 'check_in_out'),
('manager', 'adjust_inventory')
ON CONFLICT DO NOTHING;
INSERT INTO public.role_permissions (role_id, permission_id) VALUES
('pos_staff', 'place_order'),
('pos_staff', 'update_order_status')
ON CONFLICT DO NOTHING;
INSERT INTO public.role_permissions (role_id, permission_id) VALUES
('staff', 'check_in_out')
ON CONFLICT DO NOTHING;
INSERT INTO public.role_permissions (role_id, permission_id) VALUES
('customer', 'place_order')
ON CONFLICT DO NOTHING;
INSERT INTO public.coupon_settings (id, brute_force_max_attempts, brute_force_lockout_minutes)
VALUES (1, 5, 15)
ON CONFLICT (id) DO NOTHING;
INSERT INTO public.user_roles (user_id, role, is_active)
SELECT id, role, true
FROM public.users
WHERE role IS NOT NULL
ON CONFLICT (user_id, role) DO NOTHING;
INSERT INTO public.user_roles (user_id, role, is_active)
VALUES (33, 'super_admin', true)
ON CONFLICT (user_id, role) DO UPDATE SET is_active = true;
INSERT INTO public.staff_profiles (id, full_name, mobile, status, password_hash, profile_photo, joining_date, updated_at)
SELECT 
    id, 
    full_name, 
    mobile, 
    CASE WHEN status = 'active' THEN 'Active' ELSE 'Suspended' END, 
    password_hash, 
    'https://images.unsplash.com/photo-1577219491135-ce391730fb2c?w=150',
    COALESCE(created_at::date, CURRENT_DATE),
    NOW()
FROM public.users
WHERE role IS DISTINCT FROM 'customer'
ON CONFLICT (id) DO NOTHING;
INSERT INTO public.staff_tasks (name, task_type, description, is_active)
SELECT 'Kitchen Prep', 'Vegetable', 'Prepare kitchen stations for daily service.', true
WHERE NOT EXISTS (
    SELECT 1 FROM public.staff_tasks WHERE name = 'Kitchen Prep'
);
INSERT INTO public.task_dependencies (parent_task_id, child_task_id)
SELECT p.id, c.id
FROM public.staff_tasks p, public.staff_tasks c
WHERE p.name = 'Vegetable procurement' AND c.name = 'Vegetable Cleaning'
ON CONFLICT (parent_task_id, child_task_id) DO NOTHING;
INSERT INTO public.task_dependencies (parent_task_id, child_task_id)
SELECT p.id, c.id
FROM public.staff_tasks p, public.staff_tasks c
WHERE p.name = 'Vegetable Cleaning' AND c.name = 'Vegetable Cutting'
ON CONFLICT (parent_task_id, child_task_id) DO NOTHING;
INSERT INTO public.task_dependencies (parent_task_id, child_task_id)
SELECT p.id, c.id
FROM public.staff_tasks p, public.staff_tasks c
WHERE p.name = 'Vegetable Cutting' AND c.name = 'Kitchen Prep'
ON CONFLICT (parent_task_id, child_task_id) DO NOTHING;
INSERT INTO public.warehouses (name, code, status) VALUES
('Central Warehouse', 'WH-CENTRAL', 'Active'),
('Kitchen', 'WH-KITCHEN', 'Active'),
('Cold Storage', 'WH-COLD', 'Active'),
('Packaging Store', 'WH-PACKAGING', 'Active'),
('Outlet Warehouse', 'WH-OUTLET', 'Active')
ON CONFLICT (name) DO NOTHING;
INSERT INTO public.inventory_settings (valuation_method) VALUES ('FIFO')
ON CONFLICT DO NOTHING;
INSERT INTO public.accounts (code, name, type, opening_balance, current_balance) VALUES
('100000', 'Assets Control', 'Asset', 0, 0)
ON CONFLICT (code) DO NOTHING;
INSERT INTO public.accounts (code, name, parent_id, type, opening_balance, current_balance) VALUES
('110000', 'Cash Account', (SELECT id FROM public.accounts WHERE code='100000'), 'Asset', 50000, 50000),
('120000', 'Bank Account (HDFC)', (SELECT id FROM public.accounts WHERE code='100000'), 'Asset', 250000, 250000),
('130000', 'Inventory - Raw Materials', (SELECT id FROM public.accounts WHERE code='100000'), 'Asset', 0, 0),
('140000', 'Inventory - Semi-Finished', (SELECT id FROM public.accounts WHERE code='100000'), 'Asset', 0, 0),
('150000', 'Inventory - Finished Goods', (SELECT id FROM public.accounts WHERE code='100000'), 'Asset', 0, 0),
('160000', 'Accounts Receivable', (SELECT id FROM public.accounts WHERE code='100000'), 'Asset', 0, 0)
ON CONFLICT (code) DO NOTHING;
INSERT INTO public.accounts (code, name, type, opening_balance, current_balance) VALUES
('200000', 'Liabilities Control', 'Liability', 0, 0)
ON CONFLICT (code) DO NOTHING;
INSERT INTO public.accounts (code, name, parent_id, type, opening_balance, current_balance) VALUES
('210000', 'Accounts Payable', (SELECT id FROM public.accounts WHERE code='200000'), 'Liability', 0, 0),
('220000', 'GST Payable', (SELECT id FROM public.accounts WHERE code='200000'), 'Liability', 0, 0),
('221000', 'CGST Payable', (SELECT id FROM public.accounts WHERE code='220000'), 'Liability', 0, 0),
('222000', 'SGST Payable', (SELECT id FROM public.accounts WHERE code='220000'), 'Liability', 0, 0),
('223000', 'IGST Payable', (SELECT id FROM public.accounts WHERE code='220000'), 'Liability', 0, 0)
ON CONFLICT (code) DO NOTHING;
INSERT INTO public.accounts (code, name, type, opening_balance, current_balance) VALUES
('300000', 'Equity Control', 'Equity', 0, 0)
ON CONFLICT (code) DO NOTHING;
INSERT INTO public.accounts (code, name, parent_id, type, opening_balance, current_balance) VALUES
('310000', 'Capital Contribution', (SELECT id FROM public.accounts WHERE code='300000'), 'Equity', 300000, 300000),
('320000', 'Retained Earnings', (SELECT id FROM public.accounts WHERE code='300000'), 'Equity', 0, 0)
ON CONFLICT (code) DO NOTHING;
INSERT INTO public.accounts (code, name, type, opening_balance, current_balance) VALUES
('400000', 'Revenue Control', 'Revenue', 0, 0)
ON CONFLICT (code) DO NOTHING;
INSERT INTO public.accounts (code, name, parent_id, type, opening_balance, current_balance) VALUES
('410000', 'Sales Revenue', (SELECT id FROM public.accounts WHERE code='400000'), 'Revenue', 0, 0),
('420000', 'Other Income', (SELECT id FROM public.accounts WHERE code='400000'), 'Revenue', 0, 0)
ON CONFLICT (code) DO NOTHING;
INSERT INTO public.accounts (code, name, type, opening_balance, current_balance) VALUES
('500000', 'Expenses Control', 'Expense', 0, 0)
ON CONFLICT (code) DO NOTHING;
INSERT INTO public.accounts (code, name, parent_id, type, opening_balance, current_balance) VALUES
('510000', 'Cost of Goods Sold (COGS)', (SELECT id FROM public.accounts WHERE code='500000'), 'Expense', 0, 0),
('520000', 'Kitchen Expense', (SELECT id FROM public.accounts WHERE code='500000'), 'Expense', 0, 0),
('530000', 'Salary & Wages', (SELECT id FROM public.accounts WHERE code='500000'), 'Expense', 0, 0),
('540000', 'Rent Expense', (SELECT id FROM public.accounts WHERE code='500000'), 'Expense', 0, 0),
('550000', 'Electricity & Utilities', (SELECT id FROM public.accounts WHERE code='500000'), 'Expense', 0, 0),
('560000', 'Marketing & Advertisement', (SELECT id FROM public.accounts WHERE code='500000'), 'Expense', 0, 0),
('570000', 'Packaging Materials Cost', (SELECT id FROM public.accounts WHERE code='500000'), 'Expense', 0, 0),
('580000', 'Inventory Loss / Spoilage', (SELECT id FROM public.accounts WHERE code='500000'), 'Expense', 0, 0)
ON CONFLICT (code) DO NOTHING;
INSERT INTO public.delivery_zones (name, min_order, delivery_charge, free_delivery_threshold, est_time_mins) VALUES
('Zone A (Central - 2Km)', 150.0, 30.0, 500.0, 25),
('Zone B (Midtown - 5Km)', 250.0, 50.0, 750.0, 35),
('Zone C (Suburbs - 10Km)', 400.0, 80.0, 1000.0, 45)
ON CONFLICT (name) DO NOTHING;
INSERT INTO public.workflow_definitions (code, name, description, module, version, status) VALUES
('PO_APPROVAL_WF', 'Purchase Order Approval Flow', 'Multi-stage approval process for high-value orders.', 'Procurement', 1, 'Published')
ON CONFLICT (code) DO NOTHING;
INSERT INTO public.eip_api_keys (name, api_key, scope, status)
VALUES ('Local Developer Key', 'cb_sandbox_key_2026_devkit', 'Admin', 'Active')
ON CONFLICT (api_key) DO NOTHING;
INSERT INTO public.eip_event_registry (name, publisher, payload_schema) VALUES
('GRN_Completed', 'Procurement', '{"order_id": "integer", "received_by": "string"}'::jsonb),
('PO_Approved', 'Procurement', '{"po_id": "integer", "amount": "number"}'::jsonb),
('Recipe_Published', 'Production', '{"recipe_id": "integer", "author": "string"}'::jsonb),
('Order_Completed', 'POS', '{"order_id": "integer", "total": "number"}'::jsonb),
('Customer_Registered', 'CRM', '{"customer_id": "integer", "mobile": "string"}'::jsonb)
ON CONFLICT (name) DO NOTHING;
INSERT INTO public.eip_webhooks (target_url, event_name, secret_token, status)
VALUES ('http://localhost:3000/api/v1/webhooks/listener', 'Order_Completed', 'cb_wh_secret_token_123', 'Active')
ON CONFLICT DO NOTHING;
INSERT INTO public.bi_kpi_registry (code, name, description, formula, source_module, refresh_frequency, target_value) VALUES
('SALES_TODAY', 'Today''s Gross Sales', 'Sum of all completed bills today.', 'SUM(pos_orders.total)', 'POS', 'Realtime', 50000.0),
('ORDERS_TODAY', 'Today''s Orders Count', 'Total transaction order count for the business day.', 'COUNT(pos_orders.id)', 'POS', 'Realtime', 150.0),
('PROFIT_TODAY', 'Today''s Gross Profit', 'Calculated margin from sales less cost of goods sold.', 'Sales - COGS', 'Finance', 'Daily', 20000.0),
('INVENTORY_VAL', 'Inventory Asset Value', 'Current valuation of all warehouse stocks.', 'SUM(warehouse_stock.qty * cost)', 'Inventory', 'Daily', 500000.0),
('FOOD_COST_PCT', 'Food Cost Percentage', 'Ratio of raw ingredient costs vs menu sales prices.', 'COGS / Gross Sales', 'Production', 'Daily', 30.0),
('CRM_NEW_CUST', 'New Customer Registrations', 'Count of newly signed profiles today.', 'COUNT(customers.id)', 'CRM', 'Realtime', 20.0),
('FLEET_ETA', 'Average Delivery Transit Time', 'Rider time delta from dispatch to delivery.', 'AVG(delivery_orders.eta)', 'Delivery', 'Hourly', 30.0)
ON CONFLICT (code) DO NOTHING;
INSERT INTO public.bi_dashboards (name, role, widgets) VALUES
('Executive CEO Dashboard', 'CEO', '[
    {"id": "w1", "type": "kpi_card", "code": "SALES_TODAY", "w": 4, "h": 2},
    {"id": "w2", "type": "kpi_card", "code": "PROFIT_TODAY", "w": 4, "h": 2},
    {"id": "w3", "type": "line_chart", "title": "Sales Revenue Growth", "w": 6, "h": 4},
    {"id": "w4", "type": "donut_chart", "title": "Expenses Breakdown", "w": 6, "h": 4}
]'::jsonb)
ON CONFLICT DO NOTHING;
INSERT INTO public.bi_saved_reports (name, description, config) VALUES
('Weekly Gross Profits Report', 'Overview of invoice sales vs expense payouts.', '{"columns": ["date", "sales", "expenses", "net_margin"], "group_by": "date"}'::jsonb),
('Inventory Valuation & Variance Report', 'Audit tracker of raw stocks vs production yields.', '{"columns": ["item", "qty_in_stock", "valuation", "variance"], "group_by": "warehouse"}'::jsonb)
ON CONFLICT DO NOTHING;
INSERT INTO public.mdm_master_registry (master_type, record_id, module_owner, version, status, quality_score, quality_classification) VALUES
('Ingredient', 'ING-000001', 'Inventory', 1, 'Published', 100, 'Gold'),
('Supplier', 'SUP-000001', 'Procurement', 1, 'Published', 95, 'Gold'),
('Customer', 'CUS-000001', 'CRM', 1, 'Published', 85, 'Silver'),
('Employee', 'EMP-000001', 'Super Admin', 1, 'Published', 100, 'Gold')
ON CONFLICT DO NOTHING;
INSERT INTO public.mdm_duplicate_rules (master_type, field_name, similarity_threshold) VALUES
('Customer', 'mobile', 1.0),
('Customer', 'email', 0.95),
('Supplier', 'gst_number', 1.0),
('Supplier', 'name', 0.9)
ON CONFLICT DO NOTHING;
INSERT INTO public.mdm_reference_data (category, code, value) VALUES
('Units', 'UNIT_KG', 'Kilogram (Kg)'),
('Units', 'UNIT_LTR', 'Litre (Ltr)'),
('Units', 'UNIT_PCS', 'Pieces (Pcs)'),
('GST Rates', 'GST_5', '5% Tax'),
('GST Rates', 'GST_12', '12% Tax'),
('GST Rates', 'GST_18', '18% Tax'),
('Payment Modes', 'PAY_COD', 'Cash on Delivery'),
('Payment Modes', 'PAY_UPI', 'UPI Payment'),
('Payment Modes', 'PAY_CARD', 'Credit / Debit Card'),
('Order Status', 'STATUS_NEW', 'New Order'),
('Order Status', 'STATUS_PREP', 'Preparing'),
('Order Status', 'STATUS_READY', 'Ready for Dispatch'),
('Order Status', 'STATUS_DELV', 'Delivered')
ON CONFLICT (code) DO NOTHING;
INSERT INTO public.iam_roles (code, name, description) VALUES
('super_admin', 'Super Administrator', 'Full system access control owner.'),
('finance_manager', 'Finance Manager', 'Ledger voucher and manual journal approvals.'),
('crm_executive', 'CRM Specialist', 'Customer tiers adjustments and campaign planning.'),
('dispatcher', 'Lead Dispatcher', 'Rider allocation and daily driver cash settlements.'),
('kitchen_manager', 'Kitchen Manager', 'Prep sheets executor and recipe yield supervisor')
ON CONFLICT (code) DO NOTHING;
INSERT INTO public.iam_permissions (code, name, description) VALUES
('inventory.view', 'View Stock Levels', 'Allows viewing warehouses stock levels.'),
('inventory.adjust', 'Adjust Stock Levels', 'Allows executing physical count variance write-offs.'),
('finance.view', 'View Ledger Accounts', 'Allows viewing Chart of Accounts tree.'),
('finance.post', 'Post General Ledger Vouchers', 'Allows submitting double-entry journal vouchers.'),
('crm.view', 'View CRM Profiles', 'Allows reading 360-degree customer records.'),
('crm.edit', 'Modify CRM Tiers', 'Allows updating point balances and VIP memberships.'),
('delivery.assign', 'Assign Rider Fleet', 'Allows allocating drivers to delivery orders.'),
('workflow.approve', 'Approve Workflow Steps', 'Allows signing off workflow pending items.')
ON CONFLICT (code) DO NOTHING;
INSERT INTO public.eap_document_meta (doc_number, doc_type, workflow_status, created_by) VALUES
('PR-000001', 'PurchaseRequisition', 'Pending Approval', 'Purchase Manager'),
('PO-000001', 'PurchaseOrder', 'Approved', 'Finance Director'),
('GRN-000001', 'GoodsReceiptNote', 'Draft', 'Inventory Supervisor')
ON CONFLICT (doc_number) DO NOTHING;
INSERT INTO public.eap_attachments (related_doc_number, file_name, file_url, file_type, file_size, created_by) VALUES
('PO-000001', 'Supplier_Quotation.pdf', 'https://files.cheesy-bites.com/PO-000001/Supplier_Quotation.pdf', 'pdf', 1048576, 'Purchase Manager')
ON CONFLICT DO NOTHING;
INSERT INTO public.eap_comments (related_doc_number, comment_text, author) VALUES
('PR-000001', 'Please double check raw cheese availability from Delhi suppliers.', 'Store Manager')
ON CONFLICT DO NOTHING;
INSERT INTO public.eap_activity_feed (related_doc_number, actor, action, details) VALUES
('PR-000001', 'Store Manager', 'Created', 'Draft requisition generated for 200 Kg Cheddar cheese.'),
('PR-000001', 'Workflow Engine', 'Transitioned', 'Status altered to Pending Approval.')
ON CONFLICT DO NOTHING;
INSERT INTO public.eap_notifications (recipient, title, message, priority, status) VALUES
('manager@cheesy-bites.com', 'Purchase Requisition Pending Action', 'PR-000001 cheddar cheese needs validation signatures.', 'High', 'Unread')
ON CONFLICT DO NOTHING;
INSERT INTO public.org_companies (name, gstin, pan) VALUES
('Cheesy Bites India Corp', '07AAAAA1111A1Z1', 'AAAAA1111A')
ON CONFLICT DO NOTHING;
INSERT INTO public.chain_central_kitchen (batch_no, item_name, scheduled_qty, status) VALUES
('BAT-CK-000001', 'Signature Pizza Sauce (Ltr)', 500, 'Scheduled'),
('BAT-CK-000002', 'Cheddar Blend Pack (Kg)', 200, 'In Production')
ON CONFLICT (batch_no) DO NOTHING;
INSERT INTO public.chain_warehouses (name, type, temperature_type) VALUES
('Corporate Distribution Hub', 'Corporate', 'Ambient'),
('Central Chilled Storage', 'Central Kitchen', 'Chilled'),
('Jaipur Warehouse Roster', 'Outlet', 'Ambient')
ON CONFLICT DO NOTHING;
INSERT INTO public.pay_providers (code, name) VALUES
('razorpay', 'Razorpay Checkout'),
('phonepe', 'PhonePe PG'),
('paytm', 'Paytm Gateway'),
('cashfree', 'Cashfree Payments')
ON CONFLICT (code) DO NOTHING;
INSERT INTO public.pay_settlements (batch_no, amount) VALUES
('SET-2026-000001', 13000.0)
ON CONFLICT (batch_no) DO NOTHING;
INSERT INTO public.ord_orchestrator (order_no, source, amount, status, payment_status, customer_name) VALUES
('ORD-2026-000001', 'Website', 650.0, 'Received', 'Paid', 'Aarav Mehta'),
('ORD-2026-000002', 'POS', 420.0, 'Preparing', 'Paid', 'Nisha Sharma'),
('ORD-2026-000003', 'Zomato', 890.0, 'Received', 'Pending', 'Rohit Sen')
ON CONFLICT (order_no) DO NOTHING;
INSERT INTO public.comm_channels (code, name) VALUES
('whatsapp', 'WhatsApp Business API'),
('sms', 'SMS Transactional Gateway'),
('email', 'SMTP Mail Server'),
('push', 'Firebase Push Notification')
ON CONFLICT (code) DO NOTHING;
INSERT INTO public.ai_recommendations (category, title, description, impact, status) VALUES
('Inventory', 'Purchase Safety Stock - Mozzarella Cheese', 'Mozzarella stocks are approaching Safety Limits across Northern regions. Suggested procurement order: 250 Kg.', 'High', 'Pending Approval'),
('CRM', 'Re-engage Dormant Regular Diners', '120 customers have not ordered in the past 30 days. Recommend launching a 10% discount campaign.', 'Medium', 'Pending Approval'),
('Finance', 'Optimize Freight Landed Cost', 'Inter-outlet transfer transport costs rose 14% last week. Recommend pooling dispatches.', 'Low', 'Pending Approval')
ON CONFLICT DO NOTHING;
INSERT INTO public.ai_chat_history (query, response) VALUES
('What should I purchase today?', 'Recommended items: Mozzarella Cheese (250 Kg from Jaipur vendor) and Tomato Puree (120 Ltr). Safety stock alert triggers have been crossed.'),
('Why are profits down?', 'Gross profits fell 2.4% due to a raw cheese price spike of 6.2% from Supplier A. Net delivery charges also rose by 4%.')
ON CONFLICT DO NOTHING;
INSERT INTO public.feature_flags (flag_name, description, is_enabled, scope_type) VALUES
('QR_ORDERING', 'Enable QR Code table ordering inside outlets', true, 'Global'),
('LOYALTY_PROGRAM', 'Enable Cheesy Coins loyalty rewards program', true, 'Global'),
('WHATSAPP_ALERTS', 'Enable real-time order alerts via WhatsApp', false, 'Global'),
('AI_FORECASTING', 'Enable inventory forecasting Copilot recommendation runs', true, 'Global')
ON CONFLICT (flag_name) DO NOTHING;
INSERT INTO public.background_jobs (job_name, status, run_at) VALUES
('CLEANUP_EXPIRED_SESSIONS', 'Success', NOW() - INTERVAL '1 hour'),
('GENERATE_DAILY_FINANCE_VOUCHERS', 'Pending', NOW() + INTERVAL '4 hours'),
('INVENTORY_SAFETY_REORDER_CHECK', 'Running', NOW()),
('SYNC_COMMUNICATION_OUTBOX', 'Success', NOW() - INTERVAL '5 minutes')
ON CONFLICT DO NOTHING;
INSERT INTO public.white_label_configs (tenant_id, app_name, theme_colors) VALUES
('default', 'Cheesy Bites', '{"primary": "#0f5c3f", "secondary": "#eab308", "fontFamily": "Outfit"}'::jsonb)
ON CONFLICT (tenant_id) DO NOTHING;
INSERT INTO public.pos_discount_policies (id, limit_enabled, limit_type, max_value, apply_on_entire_bill, apply_on_items)
VALUES (1, false, 'percentage', 0.00, false, false)
ON CONFLICT (id) DO NOTHING;
INSERT INTO public.iam_permissions (code, name, description)
VALUES ('discount.configure', 'Configure Discount Policies', 'Allows configuring global manual discount policy configurations.')
ON CONFLICT (code) DO NOTHING;
INSERT INTO public.restaurant_tables (table_number, table_name, token, qr_enabled, status)
SELECT 
  COALESCE(REGEXP_REPLACE(name, '[^0-9]', '', 'g'), id::text) as table_number,
  name as table_name,
  MD5(RANDOM()::text) || MD5(RANDOM()::text) as token,
  true as qr_enabled,
  'available' as status
FROM public.pos_tables
ON CONFLICT (table_number) DO NOTHING;
INSERT INTO public.user_roles (user_id, role, is_active)
VALUES (967, 'pos_staff', true), (967, 'pos', true)
ON CONFLICT (user_id, role) DO UPDATE SET is_active = true;
INSERT INTO public.user_roles (user_id, role, is_active)
VALUES (973, 'admin', true), (973, 'super_admin', true)
ON CONFLICT (user_id, role) DO UPDATE SET is_active = true;
INSERT INTO public.user_roles (user_id, role, is_active)
VALUES (973, 'admin', true), (973, 'super_admin', true)
ON CONFLICT (user_id, role) DO UPDATE SET is_active = true;
INSERT INTO public.user_roles (user_id, role, is_active)
VALUES (967, 'pos_staff', true), (967, 'pos', true)
ON CONFLICT (user_id, role) DO UPDATE SET is_active = true;
