-- CHEESYOS NEXTGEN BASELINE V3 CANDIDATE: CONSTRAINTS & INDEXES
-- Target Project: sdbnibyzqtgpbexlznat

-- TABLE CONSTRAINTS (PK, FK, UNIQUE, CHECK)
ALTER TABLE ONLY public.attendance_settings ADD CONSTRAINT single_row CONSTRAINT single_row CHECK (id = 1);
ALTER TABLE ONLY public.opening_checklists ADD CONSTRAINT opening_checklists_staff_id_date_key CONSTRAINT opening_checklists_staff_id_date_key UNIQUE (staff_id, date);
ALTER TABLE ONLY public.opening_checklists ADD CONSTRAINT opening_checklists_staff_id_fkey CONSTRAINT opening_checklists_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES public.staff_profiles(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.closing_checklists ADD CONSTRAINT closing_checklists_staff_id_date_key CONSTRAINT closing_checklists_staff_id_date_key UNIQUE (staff_id, date);
ALTER TABLE ONLY public.closing_checklists ADD CONSTRAINT closing_checklists_staff_id_fkey CONSTRAINT closing_checklists_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES public.staff_profiles(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.role_permissions ADD PRIMARY KEY (role_id, permission_id);
ALTER TABLE ONLY public.user_permissions ADD CONSTRAINT fk_user_permissions_user_id CONSTRAINT fk_user_permissions_user_id FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.user_permissions ADD PRIMARY KEY (user_id, permission_id);
ALTER TABLE ONLY public.coupon_settings ADD CONSTRAINT single_row CONSTRAINT single_row CHECK (id = 1);
ALTER TABLE ONLY public.staff_attendance ADD CONSTRAINT fk_staff_attendance_staff_id CONSTRAINT fk_staff_attendance_staff_id FOREIGN KEY (staff_id) REFERENCES public.users(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.staff_attendance ADD CONSTRAINT staff_attendance_staff_id_fkey CONSTRAINT staff_attendance_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES public.staff_profiles(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.leave_requests ADD CONSTRAINT fk_leave_requests_staff_id CONSTRAINT fk_leave_requests_staff_id FOREIGN KEY (staff_id) REFERENCES public.users(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.leave_requests ADD CONSTRAINT leave_requests_staff_id_fkey CONSTRAINT leave_requests_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES public.staff_profiles(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.user_roles ADD CONSTRAINT user_roles_user_id_role_key CONSTRAINT user_roles_user_id_role_key UNIQUE (user_id, role);
ALTER TABLE ONLY public.staff_profiles ADD CONSTRAINT staff_profiles_id_fkey CONSTRAINT staff_profiles_id_fkey FOREIGN KEY (id) REFERENCES public.users(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.stock_entries ADD CONSTRAINT stock_entries_staff_id_fkey CONSTRAINT stock_entries_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES public.staff_profiles(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.evening_cleaning_logs ADD CONSTRAINT evening_cleaning_logs_staff_id_date_key CONSTRAINT evening_cleaning_logs_staff_id_date_key UNIQUE (staff_id, date);
ALTER TABLE ONLY public.evening_cleaning_logs ADD CONSTRAINT evening_cleaning_logs_staff_id_fkey CONSTRAINT evening_cleaning_logs_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES public.staff_profiles(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.vegetable_cleaning_logs ADD CONSTRAINT vegetable_cleaning_logs_staff_id_fkey CONSTRAINT vegetable_cleaning_logs_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES public.staff_profiles(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.equipment_cleaning_logs ADD CONSTRAINT equipment_cleaning_logs_staff_id_fkey CONSTRAINT equipment_cleaning_logs_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES public.staff_profiles(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.food_wastage_logs ADD CONSTRAINT food_wastage_logs_staff_id_fkey CONSTRAINT food_wastage_logs_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES public.staff_profiles(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.task_assignments ADD CONSTRAINT task_assignments_staff_id_fkey CONSTRAINT task_assignments_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES public.staff_profiles(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.task_completion_logs ADD CONSTRAINT task_completion_logs_staff_id_fkey CONSTRAINT task_completion_logs_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES public.staff_profiles(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.inventory_assignments ADD CONSTRAINT inventory_assignments_staff_id_fkey CONSTRAINT inventory_assignments_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES public.staff_profiles(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.staff_alerts ADD CONSTRAINT staff_alerts_staff_id_fkey CONSTRAINT staff_alerts_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES public.staff_profiles(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.daily_inventory_logs ADD UNIQUE(date, staff_id, item_type);
ALTER TABLE ONLY public.task_dependencies ADD UNIQUE(parent_task_id, child_task_id);
ALTER TABLE ONLY public.meal_groups ADD CONSTRAINT meal_groups_group_type_check CONSTRAINT meal_groups_group_type_check CHECK (group_type IN ('selection', 'included', 'upgrade'));
ALTER TABLE ONLY public.products ADD CONSTRAINT fk_products_categories CONSTRAINT fk_products_categories FOREIGN KEY (category_id)
REFERENCES public.categories(id)
ON DELETE SET NULL;
ALTER TABLE ONLY public.warehouse_stock ADD UNIQUE(warehouse_id, ingredient_id);
ALTER TABLE ONLY public.iam_role_permissions ADD CONSTRAINT uq_role_permission CONSTRAINT uq_role_permission UNIQUE (role_id, permission_id);
ALTER TABLE ONLY public.restaurant_tables ADD CONSTRAINT fk_active_session CONSTRAINT fk_active_session FOREIGN KEY (active_session_id) REFERENCES public.table_sessions(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.choice_group_products ADD CONSTRAINT unique_group_product CONSTRAINT unique_group_product UNIQUE (choice_group_id, product_id);
ALTER TABLE ONLY public.meal_template_groups ADD CONSTRAINT unique_template_group CONSTRAINT unique_template_group UNIQUE (meal_template_id, choice_group_id);
ALTER TABLE ONLY public.meal_product_versions ADD CONSTRAINT unique_product_version CONSTRAINT unique_product_version UNIQUE (meal_product_id, version_number);
ALTER TABLE ONLY public.meal_product_upgrade_rules ADD CONSTRAINT unique_meal_upgrade CONSTRAINT unique_meal_upgrade UNIQUE (meal_product_id, choice_group_id, base_product_id, upgrade_product_id);
ALTER TABLE ONLY public.kot_corrections ADD CONSTRAINT kot_corrections_correction_id_key constraint kot_corrections_correction_id_key unique (correction_id);
ALTER TABLE ONLY public.kot_corrections ADD CONSTRAINT kot_corrections_line_session_key constraint kot_corrections_line_session_key unique (line_id, edit_session_id);
ALTER TABLE ONLY public.pos_kots ADD CONSTRAINT pos_kots_kot_event_id_key CONSTRAINT pos_kots_kot_event_id_key UNIQUE (kot_event_id);
ALTER TABLE ONLY public.pos_kot_items ADD CONSTRAINT pos_kot_items_unique_event_line CONSTRAINT pos_kot_items_unique_event_line UNIQUE (kot_event_id, session_item_id, item_ordinal);
ALTER TABLE ONLY public.pos_kot_print_reports ADD CONSTRAINT pos_kot_print_reports_unique_receipt CONSTRAINT pos_kot_print_reports_unique_receipt UNIQUE (kot_event_id, print_job_id);
ALTER TABLE ONLY public.ready_inventory_items ADD CONSTRAINT ready_inventory_items_name_chk CONSTRAINT ready_inventory_items_name_chk CHECK (length(btrim(name)) BETWEEN 1 AND 120);
ALTER TABLE ONLY public.ready_inventory_items ADD CONSTRAINT ready_inventory_items_unit_chk CONSTRAINT ready_inventory_items_unit_chk CHECK (length(btrim(unit)) BETWEEN 1 AND 30);
ALTER TABLE ONLY public.ready_inventory_items ADD CONSTRAINT ready_inventory_items_low_stock_chk CONSTRAINT ready_inventory_items_low_stock_chk CHECK (low_stock_level >= 0);
ALTER TABLE ONLY public.ready_inventory_menu_mappings ADD CONSTRAINT ready_inventory_menu_mappings_qty_chk CONSTRAINT ready_inventory_menu_mappings_qty_chk CHECK (qty_per_sale > 0 AND qty_per_sale <= 1000);
ALTER TABLE ONLY public.ready_inventory_movements ADD CONSTRAINT ready_inventory_movements_delta_nonzero_chk CONSTRAINT ready_inventory_movements_delta_nonzero_chk CHECK (quantity_delta <> 0);
ALTER TABLE ONLY public.ready_inventory_movements ADD CONSTRAINT ready_inventory_movements_balance_chk CONSTRAINT ready_inventory_movements_balance_chk CHECK (stock_after = stock_before + quantity_delta);
ALTER TABLE ONLY public.ready_inventory_movements ADD CONSTRAINT ready_inventory_movements_type_chk CONSTRAINT ready_inventory_movements_type_chk CHECK (movement_type IN ('OPENING', 'PURCHASE', 'ADJUSTMENT_IN', 'ADJUSTMENT_OUT', 'SALE'));
ALTER TABLE ONLY public.ready_inventory_movements ADD CONSTRAINT ready_inventory_movements_source_chk CONSTRAINT ready_inventory_movements_source_chk CHECK (source_type IN ('MANUAL', 'POS', 'WEBSITE'));
ALTER TABLE ONLY public.ready_inventory_movements ADD CONSTRAINT ready_inventory_movements_sign_chk CONSTRAINT ready_inventory_movements_sign_chk CHECK (
        (movement_type IN ('OPENING', 'PURCHASE', 'ADJUSTMENT_IN') AND quantity_delta > 0)
        OR (movement_type IN ('ADJUSTMENT_OUT', 'SALE') AND quantity_delta < 0)
    );
ALTER TABLE ONLY public.ready_inventory_sale_failures ADD CONSTRAINT ready_inventory_sale_failures_source_chk CONSTRAINT ready_inventory_sale_failures_source_chk CHECK (source_type IN ('POS', 'WEBSITE'));
ALTER TABLE ONLY public.ready_inventory_sale_failures ADD CONSTRAINT ready_inventory_sale_failures_op_chk CONSTRAINT ready_inventory_sale_failures_op_chk CHECK (operation IN ('SALE_DEDUCTION'));

-- INDEXES
CREATE INDEX IF NOT EXISTS cheesy_wallets_user_id_idx ON public.cheesy_wallets (user_id)
CREATE INDEX IF NOT EXISTS cheesy_wallet_transactions_user_id_idx ON public.cheesy_wallet_transactions (user_id)
CREATE UNIQUE INDEX IF NOT EXISTS pos_orders_offline_sync_id_idx ON public.pos_orders (offline_sync_id) WHERE offline_sync_id IS NOT NULL
CREATE UNIQUE INDEX IF NOT EXISTS delivery_orders_offline_sync_id_idx ON public.delivery_orders (offline_sync_id) WHERE offline_sync_id IS NOT NULL
CREATE INDEX IF NOT EXISTS payment_transactions_order_id_idx ON public.payment_transactions (order_id)
CREATE INDEX IF NOT EXISTS payment_verification_logs_order_id_idx ON public.payment_verification_logs (order_id)
CREATE INDEX IF NOT EXISTS idx_warehouse_stock_ing_wh ON public.warehouse_stock(ingredient_id, warehouse_id)
CREATE INDEX IF NOT EXISTS idx_journal_lines_acc_debit_credit ON public.journal_lines(account_id, debit, credit)
CREATE INDEX IF NOT EXISTS idx_workflow_tasks_inst_role ON public.workflow_tasks(instance_id, assigned_role)
CREATE INDEX IF NOT EXISTS idx_pos_orders_phone_status ON public.pos_orders(phone, status)
CREATE INDEX IF NOT EXISTS idx_pos_orders_status_created ON public.pos_orders(status, created_at DESC)
CREATE INDEX IF NOT EXISTS idx_inventory_audit_logs_event_date ON public.inventory_audit_logs(event_date DESC)
CREATE INDEX IF NOT EXISTS idx_ingredient_master_id_name ON public.ingredient_master(id, name)
CREATE INDEX IF NOT EXISTS customer_rewards_log_user_id_idx ON public.customer_rewards_log (user_id)
CREATE INDEX IF NOT EXISTS idx_choice_group_products_group_id ON public.choice_group_products(choice_group_id)
CREATE INDEX IF NOT EXISTS idx_choice_group_products_product_id ON public.choice_group_products(product_id)
CREATE INDEX IF NOT EXISTS idx_meal_templates_meal_type ON public.meal_templates(meal_type)
CREATE INDEX IF NOT EXISTS idx_meal_template_groups_template_id ON public.meal_template_groups(meal_template_id)
CREATE INDEX IF NOT EXISTS idx_meal_template_groups_choice_group_id ON public.meal_template_groups(choice_group_id)
CREATE INDEX IF NOT EXISTS idx_meal_included_products_template_id ON public.meal_included_products(meal_template_id)
CREATE INDEX IF NOT EXISTS idx_meal_included_products_product_id ON public.meal_included_products(product_id)
CREATE INDEX IF NOT EXISTS idx_products_meal_template_id ON public.products(meal_template_id)
CREATE INDEX IF NOT EXISTS idx_meal_product_versions_meal_product_id ON public.meal_product_versions(meal_product_id)
CREATE INDEX IF NOT EXISTS idx_meal_product_upgrade_rules_meal_product_id ON public.meal_product_upgrade_rules(meal_product_id)
CREATE INDEX IF NOT EXISTS idx_meal_product_upgrade_rules_group_id ON public.meal_product_upgrade_rules(choice_group_id)
CREATE INDEX IF NOT EXISTS idx_meal_product_upgrade_rules_base_id ON public.meal_product_upgrade_rules(base_product_id)
CREATE INDEX IF NOT EXISTS idx_meal_product_upgrade_rules_upgrade_id ON public.meal_product_upgrade_rules(upgrade_product_id)
create index if not exists idx_kot_corrections_order_id on public.kot_corrections(order_id)
create index if not exists idx_kot_corrections_line_id on public.kot_corrections(line_id)
create index if not exists idx_kot_corrections_table_session_id on public.kot_corrections(table_session_id)
CREATE UNIQUE INDEX IF NOT EXISTS pos_order_items_order_session_item_idx
ON public.pos_order_items(order_id, session_item_id)
WHERE session_item_id IS NOT NULL
CREATE UNIQUE INDEX IF NOT EXISTS idx_pos_orders_settlement_key
ON public.pos_orders(settlement_key)
WHERE settlement_key IS NOT NULL
CREATE UNIQUE INDEX IF NOT EXISTS idx_pos_orders_cancel_key
ON public.pos_orders(cancel_key)
WHERE cancel_key IS NOT NULL
CREATE UNIQUE INDEX IF NOT EXISTS idx_pay_refunds_refund_key
ON public.pay_refunds(refund_key)
WHERE refund_key IS NOT NULL
CREATE UNIQUE INDEX IF NOT EXISTS idx_pay_refunds_gateway_refund_id
ON public.pay_refunds(gateway_refund_id)
WHERE gateway_refund_id IS NOT NULL
CREATE UNIQUE INDEX IF NOT EXISTS idx_pay_refunds_active_order_id
ON public.pay_refunds(order_id)
WHERE order_id IS NOT NULL
  AND UPPER(status) IN ('REQUESTED', 'GATEWAY_PENDING', 'COMPLETED', 'MANUAL_REVIEW_REQUIRED', 'PENDING', 'APPROVED', 'REFUNDED')
CREATE UNIQUE INDEX IF NOT EXISTS idx_pay_refunds_active_pos_order_id
ON public.pay_refunds(pos_order_id)
WHERE pos_order_id IS NOT NULL
  AND UPPER(status) IN ('REQUESTED', 'GATEWAY_PENDING', 'COMPLETED', 'MANUAL_REVIEW_REQUIRED', 'PENDING', 'APPROVED', 'REFUNDED')
CREATE UNIQUE INDEX IF NOT EXISTS idx_pay_refunds_active_delivery_order_id
ON public.pay_refunds(delivery_order_id)
WHERE delivery_order_id IS NOT NULL
  AND UPPER(status) IN ('REQUESTED', 'GATEWAY_PENDING', 'COMPLETED', 'MANUAL_REVIEW_REQUIRED', 'PENDING', 'APPROVED', 'REFUNDED')
CREATE INDEX IF NOT EXISTS idx_pos_orders_accept_key ON public.pos_orders(accept_key) WHERE accept_key IS NOT NULL
CREATE INDEX IF NOT EXISTS idx_pos_orders_rejection_key ON public.pos_orders(rejection_key) WHERE rejection_key IS NOT NULL
CREATE INDEX IF NOT EXISTS idx_pos_kots_order_id ON public.pos_kots(order_id)
CREATE INDEX IF NOT EXISTS idx_pos_kots_table_session_id ON public.pos_kots(table_session_id)
CREATE INDEX IF NOT EXISTS idx_pos_kots_offline_sync_id ON public.pos_kots(offline_sync_id)
CREATE UNIQUE INDEX IF NOT EXISTS idx_pos_kots_session_kot_num ON public.pos_kots(table_session_id, kot_number) WHERE table_session_id IS NOT NULL
CREATE UNIQUE INDEX IF NOT EXISTS idx_pos_kots_order_kot_num ON public.pos_kots(order_id, kot_number) WHERE table_session_id IS NULL
CREATE INDEX IF NOT EXISTS idx_pos_kot_items_event_id ON public.pos_kot_items(kot_event_id)
CREATE INDEX IF NOT EXISTS idx_pos_kot_items_session_item_id ON public.pos_kot_items(session_item_id)
CREATE UNIQUE INDEX IF NOT EXISTS ready_inventory_items_active_name_uidx
    ON public.ready_inventory_items (lower(btrim(name)))
    WHERE is_active
CREATE UNIQUE INDEX IF NOT EXISTS ready_inventory_menu_mappings_active_uidx
    ON public.ready_inventory_menu_mappings (product_id, COALESCE(variant_id, 0), ready_item_id)
    WHERE is_active
CREATE INDEX IF NOT EXISTS ready_inventory_menu_mappings_item_idx
    ON public.ready_inventory_menu_mappings (ready_item_id)
CREATE UNIQUE INDEX IF NOT EXISTS ready_inventory_movements_client_request_uidx
    ON public.ready_inventory_movements (client_request_id)
    WHERE client_request_id IS NOT NULL
CREATE INDEX IF NOT EXISTS ready_inventory_movements_item_created_idx
    ON public.ready_inventory_movements (ready_item_id, created_at DESC)
CREATE UNIQUE INDEX IF NOT EXISTS ready_inventory_movements_source_line_key_uidx
    ON public.ready_inventory_movements (source_line_key)
    WHERE source_line_key IS NOT NULL
CREATE UNIQUE INDEX IF NOT EXISTS ready_inventory_sale_failures_unresolved_uidx
    ON public.ready_inventory_sale_failures (source_type, source_order_id, operation)
    WHERE resolved = FALSE
CREATE UNIQUE INDEX IF NOT EXISTS idx_orders_user_idempotency_key
ON public.orders(user_id, idempotency_key)
WHERE idempotency_key IS NOT NULL AND TRIM(idempotency_key) <> ''
