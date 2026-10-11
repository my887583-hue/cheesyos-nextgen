-- CHEESYOS NEXTGEN BASELINE V2: RLS POLICIES & GRANTS
-- Target Project: sdbnibyzqtgpbexlznat

-- Enable RLS on all tables
ALTER TABLE public.accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.active_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_chat_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_recommendations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.attendance_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.background_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bi_dashboards ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bi_kpi_registry ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bi_saved_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bi_scheduled_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.branches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chain_central_kitchen ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chain_transfer_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chain_transfers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chain_warehouses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cheesy_wallet_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cheesy_wallet_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cheesy_wallets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.choice_group_products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.choice_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.comm_channels ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.comm_queue ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.comm_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.coupon_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.coupon_usage ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.coupons ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.crm_campaigns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_feedback ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_referrals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_rewards_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.daily_inventory_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.delivery_cash_settlements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.delivery_order_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.delivery_order_status_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.delivery_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.delivery_riders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.delivery_zones ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.eap_activity_feed ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.eap_attachments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.eap_comments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.eap_document_meta ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.eap_notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.eip_api_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.eip_event_bus ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.eip_event_registry ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.eip_integration_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.eip_webhooks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.expenses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.feature_flags ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.grn_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.grns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.iam_device_registry ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.iam_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.iam_role_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.iam_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.iam_security_audit ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.iam_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.incidents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ingredient_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.journal_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.journal_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.kitchen_issue_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.kitchen_issue_slips ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.kitchen_prep_sheets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.kot_corrections ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mdm_duplicate_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mdm_master_registry ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mdm_reference_data ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.meal_included_products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.meal_product_upgrade_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.meal_product_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.meal_template_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.meal_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ord_exceptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ord_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ord_orchestrator ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_meal_upgrades ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.org_cities ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.org_companies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.org_outlet_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.org_outlets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.org_regions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pay_providers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pay_refunds ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pay_settlements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pay_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment_verification_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pos_discount_policies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pos_item_discount_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pos_kot_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pos_kot_print_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pos_kots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pos_table_notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pos_tables ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_version_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.production_order_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.production_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_order_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_requisition_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_requisitions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ready_inventory_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ready_inventory_menu_mappings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ready_inventory_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ready_inventory_sale_failures ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.restaurant_tables ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.role_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.security_alerts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.security_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_adjustment_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_adjustments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_audit_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_audits ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_transfer_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_transfers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_addresses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_contacts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_price_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.support_tickets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.system_audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.table_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.task_dependencies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vendor_ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.warehouse_stock ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.warehouses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wastage_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wastage_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.white_label_configs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.workflow_conditions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.workflow_definitions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.workflow_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.workflow_instances ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.workflow_steps ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.workflow_tasks ENABLE ROW LEVEL SECURITY;

-- Deduplicated Active RLS Policies
CREATE POLICY "accounts_delete_deny_all" ON public.accounts FOR DELETE TO public USING (false);

CREATE POLICY "accounts_insert_deny_all" ON public.accounts FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "accounts_select_deny_all" ON public.accounts FOR SELECT TO public USING (false);

CREATE POLICY "accounts_update_deny_all" ON public.accounts FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete accounts" ON public.accounts FOR DELETE USING (public.is_super_admin() OR public.has_permission('finance.post'));

CREATE POLICY "Allow public insert accounts" ON public.accounts FOR INSERT WITH CHECK (public.is_super_admin() OR public.has_permission('finance.post'));

CREATE POLICY "Allow public select accounts" ON public.accounts FOR SELECT USING (public.is_super_admin() OR public.has_permission('finance.view'));

CREATE POLICY "Allow public update accounts" ON public.accounts FOR UPDATE USING (public.is_super_admin() OR public.has_permission('finance.post'));

CREATE POLICY "sessions_select" ON public.active_sessions FOR SELECT USING (true);

CREATE POLICY "addon_group_items_delete_deny_all" ON public.addon_group_items FOR DELETE TO public USING (false);

CREATE POLICY "addon_group_items_insert_deny_all" ON public.addon_group_items FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "addon_group_items_public_select" ON public.addon_group_items FOR SELECT TO public USING (true);

CREATE POLICY "addon_group_items_update_deny_all" ON public.addon_group_items FOR UPDATE TO public USING (false);

CREATE POLICY "addon_groups_delete_deny_all" ON public.addon_groups FOR DELETE TO public USING (false);

CREATE POLICY "addon_groups_insert_deny_all" ON public.addon_groups FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "addon_groups_public_select" ON public.addon_groups FOR SELECT TO public USING (true);

CREATE POLICY "addon_groups_update_deny_all" ON public.addon_groups FOR UPDATE TO public USING (false);

CREATE POLICY "addon_variant_prices_delete_deny_all" ON public.addon_variant_prices FOR DELETE TO public USING (false);

CREATE POLICY "addon_variant_prices_insert_deny_all" ON public.addon_variant_prices FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "addon_variant_prices_public_select" ON public.addon_variant_prices FOR SELECT TO public USING (true);

CREATE POLICY "addon_variant_prices_update_deny_all" ON public.addon_variant_prices FOR UPDATE TO public USING (false);

CREATE POLICY "addons_delete_deny_all" ON public.addons FOR DELETE TO public USING (false);

CREATE POLICY "addons_insert_deny_all" ON public.addons FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "addons_public_select" ON public.addons FOR SELECT TO public USING (true);

CREATE POLICY "addons_update_deny_all" ON public.addons FOR UPDATE TO public USING (false);

CREATE POLICY "admins_delete_deny_all" ON public.admins FOR DELETE TO public USING (false);

CREATE POLICY "admins_insert_deny_all" ON public.admins FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "admins_select_deny_all" ON public.admins FOR SELECT TO public USING (false);

CREATE POLICY "admins_update_deny_all" ON public.admins FOR UPDATE TO public USING (false);

CREATE POLICY "ai_chat_history_delete_deny_all" ON public.ai_chat_history FOR DELETE TO public USING (false);

CREATE POLICY "ai_chat_history_insert_deny_all" ON public.ai_chat_history FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "ai_chat_history_select_deny_all" ON public.ai_chat_history FOR SELECT TO public USING (false);

CREATE POLICY "ai_chat_history_update_deny_all" ON public.ai_chat_history FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete ai_chat_history" ON public.ai_chat_history FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert ai_chat_history" ON public.ai_chat_history FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select ai_chat_history" ON public.ai_chat_history FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update ai_chat_history" ON public.ai_chat_history FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "ai_recommendations_delete_deny_all" ON public.ai_recommendations FOR DELETE TO public USING (false);

CREATE POLICY "ai_recommendations_insert_deny_all" ON public.ai_recommendations FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "ai_recommendations_select_deny_all" ON public.ai_recommendations FOR SELECT TO public USING (false);

CREATE POLICY "ai_recommendations_update_deny_all" ON public.ai_recommendations FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete ai_recommendations" ON public.ai_recommendations FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert ai_recommendations" ON public.ai_recommendations FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select ai_recommendations" ON public.ai_recommendations FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update ai_recommendations" ON public.ai_recommendations FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public delete" ON public.attendance_settings FOR DELETE USING (true);

CREATE POLICY "Allow public insert" ON public.attendance_settings FOR INSERT WITH CHECK (true);

CREATE POLICY "Allow public select" ON public.attendance_settings FOR SELECT USING (true);

CREATE POLICY "Allow public update" ON public.attendance_settings FOR UPDATE USING (true);

CREATE POLICY "Allow public delete background_jobs" ON public.background_jobs FOR DELETE USING (public.is_super_admin());

CREATE POLICY "Allow public insert background_jobs" ON public.background_jobs FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select background_jobs" ON public.background_jobs FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update background_jobs" ON public.background_jobs FOR UPDATE USING (public.is_super_admin());

CREATE POLICY "background_jobs_delete_deny_all" ON public.background_jobs FOR DELETE TO public USING (false);

CREATE POLICY "background_jobs_insert_deny_all" ON public.background_jobs FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "background_jobs_select_deny_all" ON public.background_jobs FOR SELECT TO public USING (false);

CREATE POLICY "background_jobs_update_deny_all" ON public.background_jobs FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete bi_dashboards" ON public.bi_dashboards FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert bi_dashboards" ON public.bi_dashboards FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select bi_dashboards" ON public.bi_dashboards FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update bi_dashboards" ON public.bi_dashboards FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "bi_dashboards_delete_deny_all" ON public.bi_dashboards FOR DELETE TO public USING (false);

CREATE POLICY "bi_dashboards_insert_deny_all" ON public.bi_dashboards FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "bi_dashboards_select_deny_all" ON public.bi_dashboards FOR SELECT TO public USING (false);

CREATE POLICY "bi_dashboards_update_deny_all" ON public.bi_dashboards FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete bi_kpi_registry" ON public.bi_kpi_registry FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert bi_kpi_registry" ON public.bi_kpi_registry FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select bi_kpi_registry" ON public.bi_kpi_registry FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update bi_kpi_registry" ON public.bi_kpi_registry FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "bi_kpi_registry_delete_deny_all" ON public.bi_kpi_registry FOR DELETE TO public USING (false);

CREATE POLICY "bi_kpi_registry_insert_deny_all" ON public.bi_kpi_registry FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "bi_kpi_registry_select_deny_all" ON public.bi_kpi_registry FOR SELECT TO public USING (false);

CREATE POLICY "bi_kpi_registry_update_deny_all" ON public.bi_kpi_registry FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete bi_saved_reports" ON public.bi_saved_reports FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert bi_saved_reports" ON public.bi_saved_reports FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select bi_saved_reports" ON public.bi_saved_reports FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update bi_saved_reports" ON public.bi_saved_reports FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "bi_saved_reports_delete_deny_all" ON public.bi_saved_reports FOR DELETE TO public USING (false);

CREATE POLICY "bi_saved_reports_insert_deny_all" ON public.bi_saved_reports FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "bi_saved_reports_select_deny_all" ON public.bi_saved_reports FOR SELECT TO public USING (false);

CREATE POLICY "bi_saved_reports_update_deny_all" ON public.bi_saved_reports FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete bi_scheduled_reports" ON public.bi_scheduled_reports FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert bi_scheduled_reports" ON public.bi_scheduled_reports FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select bi_scheduled_reports" ON public.bi_scheduled_reports FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update bi_scheduled_reports" ON public.bi_scheduled_reports FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "bi_scheduled_reports_delete_deny_all" ON public.bi_scheduled_reports FOR DELETE TO public USING (false);

CREATE POLICY "bi_scheduled_reports_insert_deny_all" ON public.bi_scheduled_reports FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "bi_scheduled_reports_select_deny_all" ON public.bi_scheduled_reports FOR SELECT TO public USING (false);

CREATE POLICY "bi_scheduled_reports_update_deny_all" ON public.bi_scheduled_reports FOR UPDATE TO public USING (false);

CREATE POLICY "branches_delete_deny_all" ON public.branches FOR DELETE TO public USING (false);

CREATE POLICY "branches_insert_deny_all" ON public.branches FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "branches_public_select" ON public.branches FOR SELECT TO public USING (true);

CREATE POLICY "branches_update_deny_all" ON public.branches FOR UPDATE TO public USING (false);

CREATE POLICY "categories_delete_deny_all" ON public.categories FOR DELETE TO public USING (false);

CREATE POLICY "categories_insert_deny_all" ON public.categories FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "categories_public_select" ON public.categories FOR SELECT TO public USING (true);

CREATE POLICY "categories_update_deny_all" ON public.categories FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete chain_central_kitchen" ON public.chain_central_kitchen FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert chain_central_kitchen" ON public.chain_central_kitchen FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select chain_central_kitchen" ON public.chain_central_kitchen FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update chain_central_kitchen" ON public.chain_central_kitchen FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "chain_central_kitchen_delete_deny_all" ON public.chain_central_kitchen FOR DELETE TO public USING (false);

CREATE POLICY "chain_central_kitchen_insert_deny_all" ON public.chain_central_kitchen FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "chain_central_kitchen_select_deny_all" ON public.chain_central_kitchen FOR SELECT TO public USING (false);

CREATE POLICY "chain_central_kitchen_update_deny_all" ON public.chain_central_kitchen FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete chain_transfer_items" ON public.chain_transfer_items FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert chain_transfer_items" ON public.chain_transfer_items FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select chain_transfer_items" ON public.chain_transfer_items FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update chain_transfer_items" ON public.chain_transfer_items FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "chain_transfer_items_delete_deny_all" ON public.chain_transfer_items FOR DELETE TO public USING (false);

CREATE POLICY "chain_transfer_items_insert_deny_all" ON public.chain_transfer_items FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "chain_transfer_items_select_deny_all" ON public.chain_transfer_items FOR SELECT TO public USING (false);

CREATE POLICY "chain_transfer_items_update_deny_all" ON public.chain_transfer_items FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete chain_transfers" ON public.chain_transfers FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert chain_transfers" ON public.chain_transfers FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select chain_transfers" ON public.chain_transfers FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update chain_transfers" ON public.chain_transfers FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "chain_transfers_delete_deny_all" ON public.chain_transfers FOR DELETE TO public USING (false);

CREATE POLICY "chain_transfers_insert_deny_all" ON public.chain_transfers FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "chain_transfers_select_deny_all" ON public.chain_transfers FOR SELECT TO public USING (false);

CREATE POLICY "chain_transfers_update_deny_all" ON public.chain_transfers FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete chain_warehouses" ON public.chain_warehouses FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert chain_warehouses" ON public.chain_warehouses FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select chain_warehouses" ON public.chain_warehouses FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update chain_warehouses" ON public.chain_warehouses FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "chain_warehouses_delete_deny_all" ON public.chain_warehouses FOR DELETE TO public USING (false);

CREATE POLICY "chain_warehouses_insert_deny_all" ON public.chain_warehouses FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "chain_warehouses_select_deny_all" ON public.chain_warehouses FOR SELECT TO public USING (false);

CREATE POLICY "chain_warehouses_update_deny_all" ON public.chain_warehouses FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete" ON public.cheesy_wallet_settings FOR DELETE USING (true);

CREATE POLICY "Allow public insert" ON public.cheesy_wallet_settings FOR INSERT WITH CHECK (true);

CREATE POLICY "Allow public select" ON public.cheesy_wallet_settings FOR SELECT USING (true);

CREATE POLICY "Allow public update" ON public.cheesy_wallet_settings FOR UPDATE USING (true);

CREATE POLICY "cheesy_wallet_settings_delete_deny_all" ON public.cheesy_wallet_settings FOR DELETE TO public USING (false);

CREATE POLICY "cheesy_wallet_settings_insert_deny_all" ON public.cheesy_wallet_settings FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "cheesy_wallet_settings_select_deny_all" ON public.cheesy_wallet_settings FOR SELECT TO public USING (false);

CREATE POLICY "cheesy_wallet_settings_update_deny_all" ON public.cheesy_wallet_settings FOR UPDATE TO public USING (false);

CREATE POLICY "Select settings" ON public.cheesy_wallet_settings FOR SELECT USING (true);

CREATE POLICY "Allow public delete" ON public.cheesy_wallet_transactions FOR DELETE USING (true);

CREATE POLICY "Allow public insert" ON public.cheesy_wallet_transactions FOR INSERT WITH CHECK (true);

CREATE POLICY "Allow public select" ON public.cheesy_wallet_transactions FOR SELECT USING (true);

CREATE POLICY "Allow public update" ON public.cheesy_wallet_transactions FOR UPDATE USING (true);

CREATE POLICY "cheesy_wallet_transactions_delete_deny_all" ON public.cheesy_wallet_transactions FOR DELETE TO public USING (false);

CREATE POLICY "cheesy_wallet_transactions_insert_deny_all" ON public.cheesy_wallet_transactions FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "cheesy_wallet_transactions_select_deny_all" ON public.cheesy_wallet_transactions FOR SELECT TO public USING (false);

CREATE POLICY "cheesy_wallet_transactions_update_deny_all" ON public.cheesy_wallet_transactions FOR UPDATE TO public USING (false);

CREATE POLICY "Select wallet transactions" ON public.cheesy_wallet_transactions FOR SELECT USING (true);

CREATE POLICY "Allow public delete" ON public.cheesy_wallets FOR DELETE USING (true);

CREATE POLICY "Allow public insert" ON public.cheesy_wallets FOR INSERT WITH CHECK (true);

CREATE POLICY "Allow public select" ON public.cheesy_wallets FOR SELECT USING (true);

CREATE POLICY "Allow public update" ON public.cheesy_wallets FOR UPDATE USING (true);

CREATE POLICY "cheesy_wallets_delete_deny_all" ON public.cheesy_wallets FOR DELETE TO public USING (false);

CREATE POLICY "cheesy_wallets_insert_deny_all" ON public.cheesy_wallets FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "cheesy_wallets_select_deny_all" ON public.cheesy_wallets FOR SELECT TO public USING (false);

CREATE POLICY "cheesy_wallets_update_deny_all" ON public.cheesy_wallets FOR UPDATE TO public USING (false);

CREATE POLICY "Select wallets" ON public.cheesy_wallets FOR SELECT USING (true);

CREATE POLICY "Allow public delete" ON public.choice_group_products FOR DELETE USING (true);

CREATE POLICY "Allow public insert" ON public.choice_group_products FOR INSERT WITH CHECK (true);

CREATE POLICY "Allow public select" ON public.choice_group_products FOR SELECT USING (true);

CREATE POLICY "Allow public update" ON public.choice_group_products FOR UPDATE USING (true);

CREATE POLICY "choice_group_products_delete_deny_all" ON public.choice_group_products FOR DELETE TO public USING (false);

CREATE POLICY "choice_group_products_insert_deny_all" ON public.choice_group_products FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "choice_group_products_public_select" ON public.choice_group_products FOR SELECT TO public USING (true);

CREATE POLICY "choice_group_products_update_deny_all" ON public.choice_group_products FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete" ON public.choice_groups FOR DELETE USING (true);

CREATE POLICY "Allow public insert" ON public.choice_groups FOR INSERT WITH CHECK (true);

CREATE POLICY "Allow public select" ON public.choice_groups FOR SELECT USING (true);

CREATE POLICY "Allow public update" ON public.choice_groups FOR UPDATE USING (true);

CREATE POLICY "choice_groups_delete_deny_all" ON public.choice_groups FOR DELETE TO public USING (false);

CREATE POLICY "choice_groups_insert_deny_all" ON public.choice_groups FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "choice_groups_public_select" ON public.choice_groups FOR SELECT TO public USING (true);

CREATE POLICY "choice_groups_update_deny_all" ON public.choice_groups FOR UPDATE TO public USING (false);

CREATE POLICY "combo_products_delete_deny_all" ON public.combo_products FOR DELETE TO public USING (false);

CREATE POLICY "combo_products_insert_deny_all" ON public.combo_products FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "combo_products_public_select" ON public.combo_products FOR SELECT TO public USING (true);

CREATE POLICY "combo_products_update_deny_all" ON public.combo_products FOR UPDATE TO public USING (false);

CREATE POLICY "combo_templates_delete_deny_all" ON public.combo_templates FOR DELETE TO public USING (false);

CREATE POLICY "combo_templates_insert_deny_all" ON public.combo_templates FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "combo_templates_public_select" ON public.combo_templates FOR SELECT TO public USING (true);

CREATE POLICY "combo_templates_update_deny_all" ON public.combo_templates FOR UPDATE TO public USING (false);

CREATE POLICY "combo_upgrade_rules_delete_deny_all" ON public.combo_upgrade_rules FOR DELETE TO public USING (false);

CREATE POLICY "combo_upgrade_rules_insert_deny_all" ON public.combo_upgrade_rules FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "combo_upgrade_rules_public_select" ON public.combo_upgrade_rules FOR SELECT TO public USING (true);

CREATE POLICY "combo_upgrade_rules_update_deny_all" ON public.combo_upgrade_rules FOR UPDATE TO public USING (false);

CREATE POLICY "combo_visibility_rules_delete_deny_all" ON public.combo_visibility_rules FOR DELETE TO public USING (false);

CREATE POLICY "combo_visibility_rules_insert_deny_all" ON public.combo_visibility_rules FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "combo_visibility_rules_public_select" ON public.combo_visibility_rules FOR SELECT TO public USING (true);

CREATE POLICY "combo_visibility_rules_update_deny_all" ON public.combo_visibility_rules FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete comm_channels" ON public.comm_channels FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert comm_channels" ON public.comm_channels FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select comm_channels" ON public.comm_channels FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update comm_channels" ON public.comm_channels FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "comm_channels_delete_deny_all" ON public.comm_channels FOR DELETE TO public USING (false);

CREATE POLICY "comm_channels_insert_deny_all" ON public.comm_channels FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "comm_channels_select_deny_all" ON public.comm_channels FOR SELECT TO public USING (false);

CREATE POLICY "comm_channels_update_deny_all" ON public.comm_channels FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete comm_queue" ON public.comm_queue FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert comm_queue" ON public.comm_queue FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select comm_queue" ON public.comm_queue FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update comm_queue" ON public.comm_queue FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "comm_queue_delete_deny_all" ON public.comm_queue FOR DELETE TO public USING (false);

CREATE POLICY "comm_queue_insert_deny_all" ON public.comm_queue FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "comm_queue_select_deny_all" ON public.comm_queue FOR SELECT TO public USING (false);

CREATE POLICY "comm_queue_update_deny_all" ON public.comm_queue FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete comm_templates" ON public.comm_templates FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert comm_templates" ON public.comm_templates FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select comm_templates" ON public.comm_templates FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update comm_templates" ON public.comm_templates FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "comm_templates_delete_deny_all" ON public.comm_templates FOR DELETE TO public USING (false);

CREATE POLICY "comm_templates_insert_deny_all" ON public.comm_templates FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "comm_templates_select_deny_all" ON public.comm_templates FOR SELECT TO public USING (false);

CREATE POLICY "comm_templates_update_deny_all" ON public.comm_templates FOR UPDATE TO public USING (false);

CREATE POLICY "coupon_settings_delete_deny_all" ON public.coupon_settings FOR DELETE TO public USING (false);

CREATE POLICY "coupon_settings_insert_deny_all" ON public.coupon_settings FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "coupon_settings_public_select" ON public.coupon_settings FOR SELECT TO public USING (true);

CREATE POLICY "coupon_settings_update_deny_all" ON public.coupon_settings FOR UPDATE TO public USING (false);

CREATE POLICY "coupon_usage_delete_deny_all" ON public.coupon_usage FOR DELETE TO public USING (false);

CREATE POLICY "coupon_usage_insert" ON public.coupon_usage FOR INSERT WITH CHECK (true);

CREATE POLICY "coupon_usage_insert_deny_all" ON public.coupon_usage FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "coupon_usage_select" ON public.coupon_usage FOR SELECT USING (true);

CREATE POLICY "coupon_usage_select_deny_all" ON public.coupon_usage FOR SELECT TO public USING (false);

CREATE POLICY "coupon_usage_update_deny_all" ON public.coupon_usage FOR UPDATE TO public USING (false);

CREATE POLICY "coupons_delete_deny_all" ON public.coupons FOR DELETE TO public USING (false);

CREATE POLICY "coupons_insert_deny_all" ON public.coupons FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "coupons_public_select" ON public.coupons FOR SELECT TO public USING (true);

CREATE POLICY "coupons_select" ON public.coupons FOR SELECT USING (true);

CREATE POLICY "coupons_update_deny_all" ON public.coupons FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete crm_campaigns" ON public.crm_campaigns FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert crm_campaigns" ON public.crm_campaigns FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select crm_campaigns" ON public.crm_campaigns FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update crm_campaigns" ON public.crm_campaigns FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "crm_campaigns_delete_deny_all" ON public.crm_campaigns FOR DELETE TO public USING (false);

CREATE POLICY "crm_campaigns_insert_deny_all" ON public.crm_campaigns FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "crm_campaigns_select_deny_all" ON public.crm_campaigns FOR SELECT TO public USING (false);

CREATE POLICY "crm_campaigns_update_deny_all" ON public.crm_campaigns FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete customer_feedback" ON public.customer_feedback FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert customer_feedback" ON public.customer_feedback FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select customer_feedback" ON public.customer_feedback FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update customer_feedback" ON public.customer_feedback FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "customer_feedback_delete_deny_all" ON public.customer_feedback FOR DELETE TO public USING (false);

CREATE POLICY "customer_feedback_insert_deny_all" ON public.customer_feedback FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "customer_feedback_select_deny_all" ON public.customer_feedback FOR SELECT TO public USING (false);

CREATE POLICY "customer_feedback_update_deny_all" ON public.customer_feedback FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete customer_memberships" ON public.customer_memberships FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert customer_memberships" ON public.customer_memberships FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select customer_memberships" ON public.customer_memberships FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update customer_memberships" ON public.customer_memberships FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "customer_memberships_delete_deny_all" ON public.customer_memberships FOR DELETE TO public USING (false);

CREATE POLICY "customer_memberships_insert_deny_all" ON public.customer_memberships FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "customer_memberships_select_deny_all" ON public.customer_memberships FOR SELECT TO public USING (false);

CREATE POLICY "customer_memberships_update_deny_all" ON public.customer_memberships FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete customer_referrals" ON public.customer_referrals FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert customer_referrals" ON public.customer_referrals FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select customer_referrals" ON public.customer_referrals FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update customer_referrals" ON public.customer_referrals FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "customer_referrals_delete_deny_all" ON public.customer_referrals FOR DELETE TO public USING (false);

CREATE POLICY "customer_referrals_insert_deny_all" ON public.customer_referrals FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "customer_referrals_select_deny_all" ON public.customer_referrals FOR SELECT TO public USING (false);

CREATE POLICY "customer_referrals_update_deny_all" ON public.customer_referrals FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public insert customer_rewards_log" ON public.customer_rewards_log FOR INSERT WITH CHECK (true);

CREATE POLICY "Allow public select customer_rewards_log" ON public.customer_rewards_log FOR SELECT USING (true);

CREATE POLICY "customer_rewards_log_delete_deny_all" ON public.customer_rewards_log FOR DELETE TO public USING (false);

CREATE POLICY "customer_rewards_log_insert_deny_all" ON public.customer_rewards_log FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "customer_rewards_log_select_deny_all" ON public.customer_rewards_log FOR SELECT TO public USING (false);

CREATE POLICY "customer_rewards_log_update_deny_all" ON public.customer_rewards_log FOR UPDATE TO public USING (false);

CREATE POLICY "daily_inventory_logs_delete_deny_all" ON public.daily_inventory_logs FOR DELETE TO public USING (false);

CREATE POLICY "daily_inventory_logs_insert_deny_all" ON public.daily_inventory_logs FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "daily_inventory_logs_select_deny_all" ON public.daily_inventory_logs FOR SELECT TO public USING (false);

CREATE POLICY "daily_inventory_logs_update_deny_all" ON public.daily_inventory_logs FOR UPDATE TO public USING (false);

CREATE POLICY "delete_daily_inventory_logs" ON public.daily_inventory_logs FOR DELETE
USING (public.is_super_admin() OR public.is_admin());

CREATE POLICY "insert_daily_inventory_logs" ON public.daily_inventory_logs FOR INSERT
WITH CHECK (
    public.is_super_admin() OR 
    public.is_admin() OR 
    (staff_id = public.get_current_user_id() AND date = CURRENT_DATE)
);

CREATE POLICY "select_daily_inventory_logs" ON public.daily_inventory_logs FOR SELECT
USING (true);

CREATE POLICY "update_daily_inventory_logs" ON public.daily_inventory_logs FOR UPDATE
USING (
    public.is_super_admin() OR 
    public.is_admin() OR 
    (staff_id = public.get_current_user_id() AND date = CURRENT_DATE AND investigation_status = 'Pending')
);

CREATE POLICY "Allow public delete on delivery_cash_settlements" ON public.delivery_cash_settlements FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert on delivery_cash_settlements" ON public.delivery_cash_settlements FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select on delivery_cash_settlements" ON public.delivery_cash_settlements FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update on delivery_cash_settlements" ON public.delivery_cash_settlements FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "delivery_cash_settlements_delete_deny_all" ON public.delivery_cash_settlements FOR DELETE TO public USING (false);

CREATE POLICY "delivery_cash_settlements_insert_deny_all" ON public.delivery_cash_settlements FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "delivery_cash_settlements_select_deny_all" ON public.delivery_cash_settlements FOR SELECT TO public USING (false);

CREATE POLICY "delivery_cash_settlements_update_deny_all" ON public.delivery_cash_settlements FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete on delivery_order_items" ON public.delivery_order_items FOR DELETE USING (true);

CREATE POLICY "Allow public insert on delivery_order_items" ON public.delivery_order_items FOR INSERT WITH CHECK (true);

CREATE POLICY "Allow public select on delivery_order_items" ON public.delivery_order_items FOR SELECT USING (true);

CREATE POLICY "Allow public update on delivery_order_items" ON public.delivery_order_items FOR UPDATE USING (true);

CREATE POLICY "Allow public delete on delivery_order_status_history" ON public.delivery_order_status_history FOR DELETE USING (true);

CREATE POLICY "Allow public insert on delivery_order_status_history" ON public.delivery_order_status_history FOR INSERT WITH CHECK (true);

CREATE POLICY "Allow public select on delivery_order_status_history" ON public.delivery_order_status_history FOR SELECT USING (true);

CREATE POLICY "Allow public update on delivery_order_status_history" ON public.delivery_order_status_history FOR UPDATE USING (true);

CREATE POLICY "delivery_order_status_history_delete_deny_all" ON public.delivery_order_status_history FOR DELETE TO public USING (false);

CREATE POLICY "delivery_order_status_history_insert_deny_all" ON public.delivery_order_status_history FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "delivery_order_status_history_select_deny_all" ON public.delivery_order_status_history FOR SELECT TO public USING (false);

CREATE POLICY "delivery_order_status_history_update_deny_all" ON public.delivery_order_status_history FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete on delivery_orders" ON public.delivery_orders FOR DELETE USING (true);

CREATE POLICY "Allow public insert on delivery_orders" ON public.delivery_orders FOR INSERT WITH CHECK (true);

CREATE POLICY "Allow public select on delivery_orders" ON public.delivery_orders FOR SELECT USING (true);

CREATE POLICY "Allow public update on delivery_orders" ON public.delivery_orders FOR UPDATE USING (true);

CREATE POLICY "Allow public delete on delivery_riders" ON public.delivery_riders FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert on delivery_riders" ON public.delivery_riders FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select on delivery_riders" ON public.delivery_riders FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update on delivery_riders" ON public.delivery_riders FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "delivery_riders_delete_deny_all" ON public.delivery_riders FOR DELETE TO public USING (false);

CREATE POLICY "delivery_riders_insert_deny_all" ON public.delivery_riders FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "delivery_riders_select_deny_all" ON public.delivery_riders FOR SELECT TO public USING (false);

CREATE POLICY "delivery_riders_update_deny_all" ON public.delivery_riders FOR UPDATE TO public USING (false);

CREATE POLICY "delivery_settings_delete_deny_all" ON public.delivery_settings FOR DELETE TO public USING (false);

CREATE POLICY "delivery_settings_insert_deny_all" ON public.delivery_settings FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "delivery_settings_public_select" ON public.delivery_settings FOR SELECT TO public USING (true);

CREATE POLICY "delivery_settings_update_deny_all" ON public.delivery_settings FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete on delivery_zones" ON public.delivery_zones FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert on delivery_zones" ON public.delivery_zones FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select on delivery_zones" ON public.delivery_zones FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update on delivery_zones" ON public.delivery_zones FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "delivery_zones_delete_deny_all" ON public.delivery_zones FOR DELETE TO public USING (false);

CREATE POLICY "delivery_zones_insert_deny_all" ON public.delivery_zones FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "delivery_zones_public_select" ON public.delivery_zones FOR SELECT TO public USING (true);

CREATE POLICY "delivery_zones_update_deny_all" ON public.delivery_zones FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete eap_activity_feed" ON public.eap_activity_feed FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert eap_activity_feed" ON public.eap_activity_feed FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select eap_activity_feed" ON public.eap_activity_feed FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update eap_activity_feed" ON public.eap_activity_feed FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "eap_activity_feed_delete_deny_all" ON public.eap_activity_feed FOR DELETE TO public USING (false);

CREATE POLICY "eap_activity_feed_insert_deny_all" ON public.eap_activity_feed FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "eap_activity_feed_select_deny_all" ON public.eap_activity_feed FOR SELECT TO public USING (false);

CREATE POLICY "eap_activity_feed_update_deny_all" ON public.eap_activity_feed FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete eap_attachments" ON public.eap_attachments FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert eap_attachments" ON public.eap_attachments FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select eap_attachments" ON public.eap_attachments FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update eap_attachments" ON public.eap_attachments FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "eap_attachments_delete_deny_all" ON public.eap_attachments FOR DELETE TO public USING (false);

CREATE POLICY "eap_attachments_insert_deny_all" ON public.eap_attachments FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "eap_attachments_select_deny_all" ON public.eap_attachments FOR SELECT TO public USING (false);

CREATE POLICY "eap_attachments_update_deny_all" ON public.eap_attachments FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete eap_comments" ON public.eap_comments FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert eap_comments" ON public.eap_comments FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select eap_comments" ON public.eap_comments FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update eap_comments" ON public.eap_comments FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "eap_comments_delete_deny_all" ON public.eap_comments FOR DELETE TO public USING (false);

CREATE POLICY "eap_comments_insert_deny_all" ON public.eap_comments FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "eap_comments_select_deny_all" ON public.eap_comments FOR SELECT TO public USING (false);

CREATE POLICY "eap_comments_update_deny_all" ON public.eap_comments FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete eap_document_meta" ON public.eap_document_meta FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert eap_document_meta" ON public.eap_document_meta FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select eap_document_meta" ON public.eap_document_meta FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update eap_document_meta" ON public.eap_document_meta FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "eap_document_meta_delete_deny_all" ON public.eap_document_meta FOR DELETE TO public USING (false);

CREATE POLICY "eap_document_meta_insert_deny_all" ON public.eap_document_meta FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "eap_document_meta_select_deny_all" ON public.eap_document_meta FOR SELECT TO public USING (false);

CREATE POLICY "eap_document_meta_update_deny_all" ON public.eap_document_meta FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete eap_notifications" ON public.eap_notifications FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert eap_notifications" ON public.eap_notifications FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select eap_notifications" ON public.eap_notifications FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update eap_notifications" ON public.eap_notifications FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "eap_notifications_delete_deny_all" ON public.eap_notifications FOR DELETE TO public USING (false);

CREATE POLICY "eap_notifications_insert_deny_all" ON public.eap_notifications FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "eap_notifications_select_deny_all" ON public.eap_notifications FOR SELECT TO public USING (false);

CREATE POLICY "eap_notifications_update_deny_all" ON public.eap_notifications FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete eip_api_keys" ON public.eip_api_keys FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert eip_api_keys" ON public.eip_api_keys FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select eip_api_keys" ON public.eip_api_keys FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update eip_api_keys" ON public.eip_api_keys FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "eip_api_keys_delete_deny_all" ON public.eip_api_keys FOR DELETE TO public USING (false);

CREATE POLICY "eip_api_keys_insert_deny_all" ON public.eip_api_keys FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "eip_api_keys_select_deny_all" ON public.eip_api_keys FOR SELECT TO public USING (false);

CREATE POLICY "eip_api_keys_update_deny_all" ON public.eip_api_keys FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete eip_event_bus" ON public.eip_event_bus FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert eip_event_bus" ON public.eip_event_bus FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select eip_event_bus" ON public.eip_event_bus FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update eip_event_bus" ON public.eip_event_bus FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "eip_event_bus_delete_deny_all" ON public.eip_event_bus FOR DELETE TO public USING (false);

CREATE POLICY "eip_event_bus_insert_deny_all" ON public.eip_event_bus FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "eip_event_bus_select_deny_all" ON public.eip_event_bus FOR SELECT TO public USING (false);

CREATE POLICY "eip_event_bus_update_deny_all" ON public.eip_event_bus FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete eip_event_registry" ON public.eip_event_registry FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert eip_event_registry" ON public.eip_event_registry FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select eip_event_registry" ON public.eip_event_registry FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update eip_event_registry" ON public.eip_event_registry FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "eip_event_registry_delete_deny_all" ON public.eip_event_registry FOR DELETE TO public USING (false);

CREATE POLICY "eip_event_registry_insert_deny_all" ON public.eip_event_registry FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "eip_event_registry_select_deny_all" ON public.eip_event_registry FOR SELECT TO public USING (false);

CREATE POLICY "eip_event_registry_update_deny_all" ON public.eip_event_registry FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete eip_integration_logs" ON public.eip_integration_logs FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert eip_integration_logs" ON public.eip_integration_logs FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select eip_integration_logs" ON public.eip_integration_logs FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update eip_integration_logs" ON public.eip_integration_logs FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "eip_integration_logs_delete_deny_all" ON public.eip_integration_logs FOR DELETE TO public USING (false);

CREATE POLICY "eip_integration_logs_insert_deny_all" ON public.eip_integration_logs FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "eip_integration_logs_select_deny_all" ON public.eip_integration_logs FOR SELECT TO public USING (false);

CREATE POLICY "eip_integration_logs_update_deny_all" ON public.eip_integration_logs FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete eip_webhooks" ON public.eip_webhooks FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert eip_webhooks" ON public.eip_webhooks FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select eip_webhooks" ON public.eip_webhooks FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update eip_webhooks" ON public.eip_webhooks FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "eip_webhooks_delete_deny_all" ON public.eip_webhooks FOR DELETE TO public USING (false);

CREATE POLICY "eip_webhooks_insert_deny_all" ON public.eip_webhooks FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "eip_webhooks_select_deny_all" ON public.eip_webhooks FOR SELECT TO public USING (false);

CREATE POLICY "eip_webhooks_update_deny_all" ON public.eip_webhooks FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete expenses" ON public.expenses FOR DELETE USING (public.is_super_admin() OR public.has_permission('finance.post'));

CREATE POLICY "Allow public insert expenses" ON public.expenses FOR INSERT WITH CHECK (public.is_super_admin() OR public.has_permission('finance.post'));

CREATE POLICY "Allow public select expenses" ON public.expenses FOR SELECT USING (public.is_super_admin() OR public.has_permission('finance.view'));

CREATE POLICY "Allow public update expenses" ON public.expenses FOR UPDATE USING (public.is_super_admin() OR public.has_permission('finance.post'));

CREATE POLICY "expenses_delete_deny_all" ON public.expenses FOR DELETE TO public USING (false);

CREATE POLICY "expenses_insert_deny_all" ON public.expenses FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "expenses_select_deny_all" ON public.expenses FOR SELECT TO public USING (false);

CREATE POLICY "expenses_update_deny_all" ON public.expenses FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete feature_flags" ON public.feature_flags FOR DELETE USING (public.is_super_admin());

CREATE POLICY "Allow public insert feature_flags" ON public.feature_flags FOR INSERT WITH CHECK (public.is_super_admin());

CREATE POLICY "Allow public select feature_flags" ON public.feature_flags FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update feature_flags" ON public.feature_flags FOR UPDATE USING (public.is_super_admin());

CREATE POLICY "feature_flags_delete_deny_all" ON public.feature_flags FOR DELETE TO public USING (false);

CREATE POLICY "feature_flags_insert_deny_all" ON public.feature_flags FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "feature_flags_public_select" ON public.feature_flags FOR SELECT TO public USING (true);

CREATE POLICY "feature_flags_update_deny_all" ON public.feature_flags FOR UPDATE TO public USING (false);

CREATE POLICY "feedbacks_delete_deny_all" ON public.feedbacks FOR DELETE TO public USING (false);

CREATE POLICY "feedbacks_insert_deny_all" ON public.feedbacks FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "feedbacks_select_deny_all" ON public.feedbacks FOR SELECT TO public USING (false);

CREATE POLICY "feedbacks_update_deny_all" ON public.feedbacks FOR UPDATE TO public USING (false);

CREATE POLICY "food_cost_history_delete_deny_all" ON public.food_cost_history FOR DELETE TO public USING (false);

CREATE POLICY "food_cost_history_insert_deny_all" ON public.food_cost_history FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "food_cost_history_select_deny_all" ON public.food_cost_history FOR SELECT TO public USING (false);

CREATE POLICY "food_cost_history_update_deny_all" ON public.food_cost_history FOR UPDATE TO public USING (false);

CREATE POLICY "goods_receipt_delete_deny_all" ON public.goods_receipt FOR DELETE TO public USING (false);

CREATE POLICY "goods_receipt_insert_deny_all" ON public.goods_receipt FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "goods_receipt_select_deny_all" ON public.goods_receipt FOR SELECT TO public USING (false);

CREATE POLICY "goods_receipt_update_deny_all" ON public.goods_receipt FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete" ON public.grn_items FOR DELETE USING (true);

CREATE POLICY "Allow public insert" ON public.grn_items FOR INSERT WITH CHECK (true);

CREATE POLICY "Allow public select" ON public.grn_items FOR SELECT USING (true);

CREATE POLICY "Allow public update" ON public.grn_items FOR UPDATE USING (true);

CREATE POLICY "grn_items_delete_deny_all" ON public.grn_items FOR DELETE TO public USING (false);

CREATE POLICY "grn_items_insert_deny_all" ON public.grn_items FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "grn_items_select_deny_all" ON public.grn_items FOR SELECT TO public USING (false);

CREATE POLICY "grn_items_update_deny_all" ON public.grn_items FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete" ON public.grns FOR DELETE USING (true);

CREATE POLICY "Allow public insert" ON public.grns FOR INSERT WITH CHECK (true);

CREATE POLICY "Allow public select" ON public.grns FOR SELECT USING (true);

CREATE POLICY "Allow public update" ON public.grns FOR UPDATE USING (true);

CREATE POLICY "grns_delete_deny_all" ON public.grns FOR DELETE TO public USING (false);

CREATE POLICY "grns_insert_deny_all" ON public.grns FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "grns_select_deny_all" ON public.grns FOR SELECT TO public USING (false);

CREATE POLICY "grns_update_deny_all" ON public.grns FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete iam_device_registry" ON public.iam_device_registry FOR DELETE USING (public.is_super_admin());

CREATE POLICY "Allow public insert iam_device_registry" ON public.iam_device_registry FOR INSERT WITH CHECK (public.is_super_admin());

CREATE POLICY "Allow public select iam_device_registry" ON public.iam_device_registry FOR SELECT USING (public.is_super_admin());

CREATE POLICY "Allow public update iam_device_registry" ON public.iam_device_registry FOR UPDATE USING (public.is_super_admin());

CREATE POLICY "iam_device_registry_delete_deny_all" ON public.iam_device_registry FOR DELETE TO public USING (false);

CREATE POLICY "iam_device_registry_insert_deny_all" ON public.iam_device_registry FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "iam_device_registry_select_deny_all" ON public.iam_device_registry FOR SELECT TO public USING (false);

CREATE POLICY "iam_device_registry_update_deny_all" ON public.iam_device_registry FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete iam_permissions" ON public.iam_permissions FOR DELETE USING (public.is_super_admin());

CREATE POLICY "Allow public insert iam_permissions" ON public.iam_permissions FOR INSERT WITH CHECK (public.is_super_admin());

CREATE POLICY "Allow public select iam_permissions" ON public.iam_permissions FOR SELECT USING (public.is_super_admin());

CREATE POLICY "Allow public update iam_permissions" ON public.iam_permissions FOR UPDATE USING (public.is_super_admin());

CREATE POLICY "iam_permissions_delete_deny_all" ON public.iam_permissions FOR DELETE TO public USING (false);

CREATE POLICY "iam_permissions_insert_deny_all" ON public.iam_permissions FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "iam_permissions_select_deny_all" ON public.iam_permissions FOR SELECT TO public USING (false);

CREATE POLICY "iam_permissions_update_deny_all" ON public.iam_permissions FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete iam_role_permissions" ON public.iam_role_permissions FOR DELETE USING (public.is_super_admin());

CREATE POLICY "Allow public insert iam_role_permissions" ON public.iam_role_permissions FOR INSERT WITH CHECK (public.is_super_admin());

CREATE POLICY "Allow public select iam_role_permissions" ON public.iam_role_permissions FOR SELECT USING (public.is_super_admin());

CREATE POLICY "Allow public update iam_role_permissions" ON public.iam_role_permissions FOR UPDATE USING (public.is_super_admin());

CREATE POLICY "iam_role_permissions_delete_deny_all" ON public.iam_role_permissions FOR DELETE TO public USING (false);

CREATE POLICY "iam_role_permissions_insert_deny_all" ON public.iam_role_permissions FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "iam_role_permissions_select_deny_all" ON public.iam_role_permissions FOR SELECT TO public USING (false);

CREATE POLICY "iam_role_permissions_update_deny_all" ON public.iam_role_permissions FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete iam_roles" ON public.iam_roles FOR DELETE USING (public.is_super_admin());

CREATE POLICY "Allow public insert iam_roles" ON public.iam_roles FOR INSERT WITH CHECK (public.is_super_admin());

CREATE POLICY "Allow public select iam_roles" ON public.iam_roles FOR SELECT USING (public.is_super_admin());

CREATE POLICY "Allow public update iam_roles" ON public.iam_roles FOR UPDATE USING (public.is_super_admin());

CREATE POLICY "iam_roles_delete_deny_all" ON public.iam_roles FOR DELETE TO public USING (false);

CREATE POLICY "iam_roles_insert_deny_all" ON public.iam_roles FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "iam_roles_select_deny_all" ON public.iam_roles FOR SELECT TO public USING (false);

CREATE POLICY "iam_roles_update_deny_all" ON public.iam_roles FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public insert iam_security_audit" ON public.iam_security_audit FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select iam_security_audit" ON public.iam_security_audit FOR SELECT USING (public.is_super_admin());

CREATE POLICY "iam_security_audit_delete_deny_all" ON public.iam_security_audit FOR DELETE TO public USING (false);

CREATE POLICY "iam_security_audit_insert_deny_all" ON public.iam_security_audit FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "iam_security_audit_select_deny_all" ON public.iam_security_audit FOR SELECT TO public USING (false);

CREATE POLICY "iam_security_audit_update_deny_all" ON public.iam_security_audit FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete iam_sessions" ON public.iam_sessions FOR DELETE USING (public.is_super_admin());

CREATE POLICY "Allow public insert iam_sessions" ON public.iam_sessions FOR INSERT WITH CHECK (public.is_super_admin());

CREATE POLICY "Allow public select iam_sessions" ON public.iam_sessions FOR SELECT USING (public.is_super_admin());

CREATE POLICY "Allow public update iam_sessions" ON public.iam_sessions FOR UPDATE USING (public.is_super_admin());

CREATE POLICY "iam_sessions_delete_deny_all" ON public.iam_sessions FOR DELETE TO public USING (false);

CREATE POLICY "iam_sessions_insert_deny_all" ON public.iam_sessions FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "iam_sessions_select_deny_all" ON public.iam_sessions FOR SELECT TO public USING (false);

CREATE POLICY "iam_sessions_update_deny_all" ON public.iam_sessions FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete incidents" ON public.incidents FOR DELETE USING (public.is_super_admin());

CREATE POLICY "Allow public insert incidents" ON public.incidents FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select incidents" ON public.incidents FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update incidents" ON public.incidents FOR UPDATE USING (public.is_super_admin() OR public.has_permission('system.admin'));

CREATE POLICY "incidents_delete_deny_all" ON public.incidents FOR DELETE TO public USING (false);

CREATE POLICY "incidents_insert_deny_all" ON public.incidents FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "incidents_select_deny_all" ON public.incidents FOR SELECT TO public USING (false);

CREATE POLICY "incidents_update_deny_all" ON public.incidents FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete" ON public.ingredient_batches FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert" ON public.ingredient_batches FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select" ON public.ingredient_batches FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update" ON public.ingredient_batches FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "ingredient_batches_delete_deny_all" ON public.ingredient_batches FOR DELETE TO public USING (false);

CREATE POLICY "ingredient_batches_insert_deny_all" ON public.ingredient_batches FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "ingredient_batches_select_deny_all" ON public.ingredient_batches FOR SELECT TO public USING (false);

CREATE POLICY "ingredient_batches_update_deny_all" ON public.ingredient_batches FOR UPDATE TO public USING (false);

CREATE POLICY "ingredient_master_delete_deny_all" ON public.ingredient_master FOR DELETE TO public USING (false);

CREATE POLICY "ingredient_master_insert_deny_all" ON public.ingredient_master FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "ingredient_master_select_deny_all" ON public.ingredient_master FOR SELECT TO public USING (false);

CREATE POLICY "ingredient_master_update_deny_all" ON public.ingredient_master FOR UPDATE TO public USING (false);

CREATE POLICY "ingredient_packaging_delete_deny_all" ON public.ingredient_packaging FOR DELETE TO public USING (false);

CREATE POLICY "ingredient_packaging_insert_deny_all" ON public.ingredient_packaging FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "ingredient_packaging_select_deny_all" ON public.ingredient_packaging FOR SELECT TO public USING (false);

CREATE POLICY "ingredient_packaging_update_deny_all" ON public.ingredient_packaging FOR UPDATE TO public USING (false);

CREATE POLICY "ingredient_stock_delete_deny_all" ON public.ingredient_stock FOR DELETE TO public USING (false);

CREATE POLICY "ingredient_stock_insert_deny_all" ON public.ingredient_stock FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "ingredient_stock_select_deny_all" ON public.ingredient_stock FOR SELECT TO public USING (false);

CREATE POLICY "ingredient_stock_update_deny_all" ON public.ingredient_stock FOR UPDATE TO public USING (false);

CREATE POLICY "ingredient_supplier_delete_deny_all" ON public.ingredient_supplier FOR DELETE TO public USING (false);

CREATE POLICY "ingredient_supplier_insert_deny_all" ON public.ingredient_supplier FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "ingredient_supplier_select_deny_all" ON public.ingredient_supplier FOR SELECT TO public USING (false);

CREATE POLICY "ingredient_supplier_update_deny_all" ON public.ingredient_supplier FOR UPDATE TO public USING (false);

CREATE POLICY "ingredient_unit_conversion_delete_deny_all" ON public.ingredient_unit_conversion FOR DELETE TO public USING (false);

CREATE POLICY "ingredient_unit_conversion_insert_deny_all" ON public.ingredient_unit_conversion FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "ingredient_unit_conversion_select_deny_all" ON public.ingredient_unit_conversion FOR SELECT TO public USING (false);

CREATE POLICY "ingredient_unit_conversion_update_deny_all" ON public.ingredient_unit_conversion FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete" ON public.inventory_assignments FOR DELETE USING (true);

CREATE POLICY "Allow public update" ON public.inventory_assignments FOR UPDATE USING (true) WITH CHECK (true);

CREATE POLICY "Allow public delete" ON public.inventory_audit_logs FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert" ON public.inventory_audit_logs FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select" ON public.inventory_audit_logs FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update" ON public.inventory_audit_logs FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "inventory_audit_logs_delete_deny_all" ON public.inventory_audit_logs FOR DELETE TO public USING (false);

CREATE POLICY "inventory_audit_logs_insert_deny_all" ON public.inventory_audit_logs FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "inventory_audit_logs_select_deny_all" ON public.inventory_audit_logs FOR SELECT TO public USING (false);

CREATE POLICY "inventory_audit_logs_update_deny_all" ON public.inventory_audit_logs FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete" ON public.inventory_settings FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert" ON public.inventory_settings FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select" ON public.inventory_settings FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update" ON public.inventory_settings FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "inventory_settings_delete_deny_all" ON public.inventory_settings FOR DELETE TO public USING (false);

CREATE POLICY "inventory_settings_insert_deny_all" ON public.inventory_settings FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "inventory_settings_select_deny_all" ON public.inventory_settings FOR SELECT TO public USING (false);

CREATE POLICY "inventory_settings_update_deny_all" ON public.inventory_settings FOR UPDATE TO public USING (false);

CREATE POLICY "inventory_topups_delete_deny_all" ON public.inventory_topups FOR DELETE TO public USING (false);

CREATE POLICY "inventory_topups_insert_deny_all" ON public.inventory_topups FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "inventory_topups_select_deny_all" ON public.inventory_topups FOR SELECT TO public USING (false);

CREATE POLICY "inventory_topups_update_deny_all" ON public.inventory_topups FOR UPDATE TO public USING (false);

CREATE POLICY "inventory_transactions_delete_deny_all" ON public.inventory_transactions FOR DELETE TO public USING (false);

CREATE POLICY "inventory_transactions_insert_deny_all" ON public.inventory_transactions FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "inventory_transactions_select_deny_all" ON public.inventory_transactions FOR SELECT TO public USING (false);

CREATE POLICY "inventory_transactions_update_deny_all" ON public.inventory_transactions FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete journals" ON public.journal_entries FOR DELETE USING (public.is_super_admin() OR public.has_permission('finance.post'));

CREATE POLICY "Allow public insert journals" ON public.journal_entries FOR INSERT WITH CHECK (public.is_super_admin() OR public.has_permission('finance.post'));

CREATE POLICY "Allow public select journals" ON public.journal_entries FOR SELECT USING (public.is_super_admin() OR public.has_permission('finance.view'));

CREATE POLICY "Allow public update journals" ON public.journal_entries FOR UPDATE USING (public.is_super_admin() OR public.has_permission('finance.post'));

CREATE POLICY "journal_entries_delete_deny_all" ON public.journal_entries FOR DELETE TO public USING (false);

CREATE POLICY "journal_entries_insert_deny_all" ON public.journal_entries FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "journal_entries_select_deny_all" ON public.journal_entries FOR SELECT TO public USING (false);

CREATE POLICY "journal_entries_update_deny_all" ON public.journal_entries FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete jlines" ON public.journal_lines FOR DELETE USING (public.is_super_admin() OR public.has_permission('finance.post'));

CREATE POLICY "Allow public insert jlines" ON public.journal_lines FOR INSERT WITH CHECK (public.is_super_admin() OR public.has_permission('finance.post'));

CREATE POLICY "Allow public select jlines" ON public.journal_lines FOR SELECT USING (public.is_super_admin() OR public.has_permission('finance.view'));

CREATE POLICY "Allow public update jlines" ON public.journal_lines FOR UPDATE USING (public.is_super_admin() OR public.has_permission('finance.post'));

CREATE POLICY "journal_lines_delete_deny_all" ON public.journal_lines FOR DELETE TO public USING (false);

CREATE POLICY "journal_lines_insert_deny_all" ON public.journal_lines FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "journal_lines_select_deny_all" ON public.journal_lines FOR SELECT TO public USING (false);

CREATE POLICY "journal_lines_update_deny_all" ON public.journal_lines FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete KII" ON public.kitchen_issue_items FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert KII" ON public.kitchen_issue_items FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select KII" ON public.kitchen_issue_items FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update KII" ON public.kitchen_issue_items FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "kitchen_issue_items_delete_deny_all" ON public.kitchen_issue_items FOR DELETE TO public USING (false);

CREATE POLICY "kitchen_issue_items_insert_deny_all" ON public.kitchen_issue_items FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "kitchen_issue_items_select_deny_all" ON public.kitchen_issue_items FOR SELECT TO public USING (false);

CREATE POLICY "kitchen_issue_items_update_deny_all" ON public.kitchen_issue_items FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete KIS" ON public.kitchen_issue_slips FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert KIS" ON public.kitchen_issue_slips FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select KIS" ON public.kitchen_issue_slips FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update KIS" ON public.kitchen_issue_slips FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "kitchen_issue_slips_delete_deny_all" ON public.kitchen_issue_slips FOR DELETE TO public USING (false);

CREATE POLICY "kitchen_issue_slips_insert_deny_all" ON public.kitchen_issue_slips FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "kitchen_issue_slips_select_deny_all" ON public.kitchen_issue_slips FOR SELECT TO public USING (false);

CREATE POLICY "kitchen_issue_slips_update_deny_all" ON public.kitchen_issue_slips FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete KPS" ON public.kitchen_prep_sheets FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert KPS" ON public.kitchen_prep_sheets FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select KPS" ON public.kitchen_prep_sheets FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update KPS" ON public.kitchen_prep_sheets FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "kitchen_prep_sheets_delete_deny_all" ON public.kitchen_prep_sheets FOR DELETE TO public USING (false);

CREATE POLICY "kitchen_prep_sheets_insert_deny_all" ON public.kitchen_prep_sheets FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "kitchen_prep_sheets_select_deny_all" ON public.kitchen_prep_sheets FOR SELECT TO public USING (false);

CREATE POLICY "kitchen_prep_sheets_update_deny_all" ON public.kitchen_prep_sheets FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete mdm_duplicate_rules" ON public.mdm_duplicate_rules FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert mdm_duplicate_rules" ON public.mdm_duplicate_rules FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select mdm_duplicate_rules" ON public.mdm_duplicate_rules FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update mdm_duplicate_rules" ON public.mdm_duplicate_rules FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "mdm_duplicate_rules_delete_deny_all" ON public.mdm_duplicate_rules FOR DELETE TO public USING (false);

CREATE POLICY "mdm_duplicate_rules_insert_deny_all" ON public.mdm_duplicate_rules FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "mdm_duplicate_rules_select_deny_all" ON public.mdm_duplicate_rules FOR SELECT TO public USING (false);

CREATE POLICY "mdm_duplicate_rules_update_deny_all" ON public.mdm_duplicate_rules FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete mdm_master_registry" ON public.mdm_master_registry FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert mdm_master_registry" ON public.mdm_master_registry FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select mdm_master_registry" ON public.mdm_master_registry FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update mdm_master_registry" ON public.mdm_master_registry FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "mdm_master_registry_delete_deny_all" ON public.mdm_master_registry FOR DELETE TO public USING (false);

CREATE POLICY "mdm_master_registry_insert_deny_all" ON public.mdm_master_registry FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "mdm_master_registry_select_deny_all" ON public.mdm_master_registry FOR SELECT TO public USING (false);

CREATE POLICY "mdm_master_registry_update_deny_all" ON public.mdm_master_registry FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete mdm_reference_data" ON public.mdm_reference_data FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert mdm_reference_data" ON public.mdm_reference_data FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select mdm_reference_data" ON public.mdm_reference_data FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update mdm_reference_data" ON public.mdm_reference_data FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "mdm_reference_data_delete_deny_all" ON public.mdm_reference_data FOR DELETE TO public USING (false);

CREATE POLICY "mdm_reference_data_insert_deny_all" ON public.mdm_reference_data FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "mdm_reference_data_select_deny_all" ON public.mdm_reference_data FOR SELECT TO public USING (false);

CREATE POLICY "mdm_reference_data_update_deny_all" ON public.mdm_reference_data FOR UPDATE TO public USING (false);

CREATE POLICY "meal_group_items_delete_deny_all" ON public.meal_group_items FOR DELETE TO public USING (false);

CREATE POLICY "meal_group_items_insert_deny_all" ON public.meal_group_items FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "meal_group_items_public_select" ON public.meal_group_items FOR SELECT TO public USING (true);

CREATE POLICY "meal_group_items_update_deny_all" ON public.meal_group_items FOR UPDATE TO public USING (false);

CREATE POLICY "meal_groups_delete_deny_all" ON public.meal_groups FOR DELETE TO public USING (false);

CREATE POLICY "meal_groups_insert_deny_all" ON public.meal_groups FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "meal_groups_public_select" ON public.meal_groups FOR SELECT TO public USING (true);

CREATE POLICY "meal_groups_update_deny_all" ON public.meal_groups FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete" ON public.meal_included_products FOR DELETE USING (true);

CREATE POLICY "Allow public insert" ON public.meal_included_products FOR INSERT WITH CHECK (true);

CREATE POLICY "Allow public select" ON public.meal_included_products FOR SELECT USING (true);

CREATE POLICY "Allow public update" ON public.meal_included_products FOR UPDATE USING (true);

CREATE POLICY "meal_included_products_delete_deny_all" ON public.meal_included_products FOR DELETE TO public USING (false);

CREATE POLICY "meal_included_products_insert_deny_all" ON public.meal_included_products FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "meal_included_products_public_select" ON public.meal_included_products FOR SELECT TO public USING (true);

CREATE POLICY "meal_included_products_update_deny_all" ON public.meal_included_products FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete" ON public.meal_product_upgrade_rules FOR DELETE USING (true);

CREATE POLICY "Allow public insert" ON public.meal_product_upgrade_rules FOR INSERT WITH CHECK (true);

CREATE POLICY "Allow public select" ON public.meal_product_upgrade_rules FOR SELECT USING (true);

CREATE POLICY "Allow public update" ON public.meal_product_upgrade_rules FOR UPDATE USING (true);

CREATE POLICY "meal_product_upgrade_rules_delete_deny_all" ON public.meal_product_upgrade_rules FOR DELETE TO public USING (false);

CREATE POLICY "meal_product_upgrade_rules_insert_deny_all" ON public.meal_product_upgrade_rules FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "meal_product_upgrade_rules_public_select" ON public.meal_product_upgrade_rules FOR SELECT TO public USING (true);

CREATE POLICY "meal_product_upgrade_rules_update_deny_all" ON public.meal_product_upgrade_rules FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete" ON public.meal_product_versions FOR DELETE USING (true);

CREATE POLICY "Allow public insert" ON public.meal_product_versions FOR INSERT WITH CHECK (true);

CREATE POLICY "Allow public select" ON public.meal_product_versions FOR SELECT USING (true);

CREATE POLICY "Allow public update" ON public.meal_product_versions FOR UPDATE USING (true);

CREATE POLICY "meal_product_versions_delete_deny_all" ON public.meal_product_versions FOR DELETE TO public USING (false);

CREATE POLICY "meal_product_versions_insert_deny_all" ON public.meal_product_versions FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "meal_product_versions_select_deny_all" ON public.meal_product_versions FOR SELECT TO public USING (false);

CREATE POLICY "meal_product_versions_update_deny_all" ON public.meal_product_versions FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete" ON public.meal_template_groups FOR DELETE USING (true);

CREATE POLICY "Allow public insert" ON public.meal_template_groups FOR INSERT WITH CHECK (true);

CREATE POLICY "Allow public select" ON public.meal_template_groups FOR SELECT USING (true);

CREATE POLICY "Allow public update" ON public.meal_template_groups FOR UPDATE USING (true);

CREATE POLICY "meal_template_groups_delete_deny_all" ON public.meal_template_groups FOR DELETE TO public USING (false);

CREATE POLICY "meal_template_groups_insert_deny_all" ON public.meal_template_groups FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "meal_template_groups_public_select" ON public.meal_template_groups FOR SELECT TO public USING (true);

CREATE POLICY "meal_template_groups_update_deny_all" ON public.meal_template_groups FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete" ON public.meal_templates FOR DELETE USING (true);

CREATE POLICY "Allow public insert" ON public.meal_templates FOR INSERT WITH CHECK (true);

CREATE POLICY "Allow public select" ON public.meal_templates FOR SELECT USING (true);

CREATE POLICY "Allow public update" ON public.meal_templates FOR UPDATE USING (true);

CREATE POLICY "meal_templates_delete_deny_all" ON public.meal_templates FOR DELETE TO public USING (false);

CREATE POLICY "meal_templates_insert_deny_all" ON public.meal_templates FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "meal_templates_public_select" ON public.meal_templates FOR SELECT TO public USING (true);

CREATE POLICY "meal_templates_update_deny_all" ON public.meal_templates FOR UPDATE TO public USING (false);

CREATE POLICY "offers_delete_deny_all" ON public.offers FOR DELETE TO public USING (false);

CREATE POLICY "offers_insert_deny_all" ON public.offers FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "offers_public_select" ON public.offers FOR SELECT TO public USING (true);

CREATE POLICY "offers_update_deny_all" ON public.offers FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete ord_exceptions" ON public.ord_exceptions FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert ord_exceptions" ON public.ord_exceptions FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select ord_exceptions" ON public.ord_exceptions FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update ord_exceptions" ON public.ord_exceptions FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "ord_exceptions_delete_deny_all" ON public.ord_exceptions FOR DELETE TO public USING (false);

CREATE POLICY "ord_exceptions_insert_deny_all" ON public.ord_exceptions FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "ord_exceptions_select_deny_all" ON public.ord_exceptions FOR SELECT TO public USING (false);

CREATE POLICY "ord_exceptions_update_deny_all" ON public.ord_exceptions FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete ord_items" ON public.ord_items FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert ord_items" ON public.ord_items FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select ord_items" ON public.ord_items FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update ord_items" ON public.ord_items FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "ord_items_delete_deny_all" ON public.ord_items FOR DELETE TO public USING (false);

CREATE POLICY "ord_items_insert_deny_all" ON public.ord_items FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "ord_items_select_deny_all" ON public.ord_items FOR SELECT TO public USING (false);

CREATE POLICY "ord_items_update_deny_all" ON public.ord_items FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete ord_orchestrator" ON public.ord_orchestrator FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert ord_orchestrator" ON public.ord_orchestrator FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select ord_orchestrator" ON public.ord_orchestrator FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update ord_orchestrator" ON public.ord_orchestrator FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "ord_orchestrator_delete_deny_all" ON public.ord_orchestrator FOR DELETE TO public USING (false);

CREATE POLICY "ord_orchestrator_insert_deny_all" ON public.ord_orchestrator FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "ord_orchestrator_select_deny_all" ON public.ord_orchestrator FOR SELECT TO public USING (false);

CREATE POLICY "ord_orchestrator_update_deny_all" ON public.ord_orchestrator FOR UPDATE TO public USING (false);

CREATE POLICY "order_meal_upgrades_delete_deny_all" ON public.order_meal_upgrades FOR DELETE TO public USING (false);

CREATE POLICY "order_meal_upgrades_insert" ON public.order_meal_upgrades FOR INSERT WITH CHECK (true);

CREATE POLICY "order_meal_upgrades_insert_deny_all" ON public.order_meal_upgrades FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "order_meal_upgrades_select" ON public.order_meal_upgrades FOR SELECT USING (true);

CREATE POLICY "order_meal_upgrades_select_deny_all" ON public.order_meal_upgrades FOR SELECT TO public USING (false);

CREATE POLICY "order_meal_upgrades_update_deny_all" ON public.order_meal_upgrades FOR UPDATE TO public USING (false);

CREATE POLICY "orders_insert" ON public.orders FOR INSERT WITH CHECK (true);

CREATE POLICY "orders_select" ON public.orders FOR SELECT USING (true);

CREATE POLICY "orders_update" ON public.orders FOR UPDATE USING (true);

CREATE POLICY "Allow public delete org_cities" ON public.org_cities FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert org_cities" ON public.org_cities FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select org_cities" ON public.org_cities FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update org_cities" ON public.org_cities FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "org_cities_delete_deny_all" ON public.org_cities FOR DELETE TO public USING (false);

CREATE POLICY "org_cities_insert_deny_all" ON public.org_cities FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "org_cities_public_select" ON public.org_cities FOR SELECT TO public USING (true);

CREATE POLICY "org_cities_update_deny_all" ON public.org_cities FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete org_companies" ON public.org_companies FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert org_companies" ON public.org_companies FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select org_companies" ON public.org_companies FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update org_companies" ON public.org_companies FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "org_companies_delete_deny_all" ON public.org_companies FOR DELETE TO public USING (false);

CREATE POLICY "org_companies_insert_deny_all" ON public.org_companies FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "org_companies_public_select" ON public.org_companies FOR SELECT TO public USING (true);

CREATE POLICY "org_companies_update_deny_all" ON public.org_companies FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete org_outlet_config" ON public.org_outlet_config FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert org_outlet_config" ON public.org_outlet_config FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select org_outlet_config" ON public.org_outlet_config FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update org_outlet_config" ON public.org_outlet_config FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "org_outlet_config_delete_deny_all" ON public.org_outlet_config FOR DELETE TO public USING (false);

CREATE POLICY "org_outlet_config_insert_deny_all" ON public.org_outlet_config FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "org_outlet_config_public_select" ON public.org_outlet_config FOR SELECT TO public USING (true);

CREATE POLICY "org_outlet_config_update_deny_all" ON public.org_outlet_config FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete org_outlets" ON public.org_outlets FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert org_outlets" ON public.org_outlets FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select org_outlets" ON public.org_outlets FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update org_outlets" ON public.org_outlets FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "org_outlets_delete_deny_all" ON public.org_outlets FOR DELETE TO public USING (false);

CREATE POLICY "org_outlets_insert_deny_all" ON public.org_outlets FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "org_outlets_public_select" ON public.org_outlets FOR SELECT TO public USING (true);

CREATE POLICY "org_outlets_update_deny_all" ON public.org_outlets FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete org_regions" ON public.org_regions FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert org_regions" ON public.org_regions FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select org_regions" ON public.org_regions FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update org_regions" ON public.org_regions FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "org_regions_delete_deny_all" ON public.org_regions FOR DELETE TO public USING (false);

CREATE POLICY "org_regions_insert_deny_all" ON public.org_regions FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "org_regions_public_select" ON public.org_regions FOR SELECT TO public USING (true);

CREATE POLICY "org_regions_update_deny_all" ON public.org_regions FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete pay_providers" ON public.pay_providers FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert pay_providers" ON public.pay_providers FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select pay_providers" ON public.pay_providers FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update pay_providers" ON public.pay_providers FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "pay_providers_delete_deny_all" ON public.pay_providers FOR DELETE TO public USING (false);

CREATE POLICY "pay_providers_insert_deny_all" ON public.pay_providers FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "pay_providers_select_deny_all" ON public.pay_providers FOR SELECT TO public USING (false);

CREATE POLICY "pay_providers_update_deny_all" ON public.pay_providers FOR UPDATE TO public USING (false);

CREATE POLICY "Allow authenticated select pay_refunds"
ON public.pay_refunds
FOR SELECT
TO authenticated
USING (true);

CREATE POLICY "Allow public delete pay_refunds" ON public.pay_refunds FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert pay_refunds" ON public.pay_refunds FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select pay_refunds" ON public.pay_refunds FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update pay_refunds" ON public.pay_refunds FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public delete pay_settlements" ON public.pay_settlements FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert pay_settlements" ON public.pay_settlements FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select pay_settlements" ON public.pay_settlements FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update pay_settlements" ON public.pay_settlements FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "pay_settlements_delete_deny_all" ON public.pay_settlements FOR DELETE TO public USING (false);

CREATE POLICY "pay_settlements_insert_deny_all" ON public.pay_settlements FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "pay_settlements_select_deny_all" ON public.pay_settlements FOR SELECT TO public USING (false);

CREATE POLICY "pay_settlements_update_deny_all" ON public.pay_settlements FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete pay_transactions" ON public.pay_transactions FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert pay_transactions" ON public.pay_transactions FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select pay_transactions" ON public.pay_transactions FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update pay_transactions" ON public.pay_transactions FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public delete" ON public.payment_transactions FOR DELETE USING (true);

CREATE POLICY "Allow public delete payments" ON public.payment_transactions FOR DELETE USING (public.is_super_admin());

CREATE POLICY "Allow public insert" ON public.payment_transactions FOR INSERT WITH CHECK (true);

CREATE POLICY "Allow public insert payments" ON public.payment_transactions FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select" ON public.payment_transactions FOR SELECT USING (true);

CREATE POLICY "Allow public select payments" ON public.payment_transactions FOR SELECT USING (public.is_super_admin() OR public.has_permission('finance.view'));

CREATE POLICY "Allow public update" ON public.payment_transactions FOR UPDATE USING (true);

CREATE POLICY "Allow public update payments" ON public.payment_transactions FOR UPDATE USING (public.is_super_admin());

CREATE POLICY "payment_transactions_delete_deny_all" ON public.payment_transactions FOR DELETE TO public USING (false);

CREATE POLICY "payment_transactions_insert_deny_all" ON public.payment_transactions FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "payment_transactions_select_deny_all" ON public.payment_transactions FOR SELECT TO public USING (false);

CREATE POLICY "payment_transactions_update_deny_all" ON public.payment_transactions FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete" ON public.payment_verification_logs FOR DELETE USING (true);

CREATE POLICY "Allow public insert" ON public.payment_verification_logs FOR INSERT WITH CHECK (true);

CREATE POLICY "Allow public select" ON public.payment_verification_logs FOR SELECT USING (true);

CREATE POLICY "Allow public update" ON public.payment_verification_logs FOR UPDATE USING (true);

CREATE POLICY "payment_verification_logs_delete_deny_all" ON public.payment_verification_logs FOR DELETE TO public USING (false);

CREATE POLICY "payment_verification_logs_insert_deny_all" ON public.payment_verification_logs FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "payment_verification_logs_select_deny_all" ON public.payment_verification_logs FOR SELECT TO public USING (false);

CREATE POLICY "payment_verification_logs_update_deny_all" ON public.payment_verification_logs FOR UPDATE TO public USING (false);

CREATE POLICY "permissions_delete_deny_all" ON public.permissions FOR DELETE TO public USING (false);

CREATE POLICY "permissions_insert_deny_all" ON public.permissions FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "permissions_select_deny_all" ON public.permissions FOR SELECT TO public USING (false);

CREATE POLICY "permissions_update_deny_all" ON public.permissions FOR UPDATE TO public USING (false);

CREATE POLICY "pos_cashiers_delete_deny_all" ON public.pos_cashiers FOR DELETE TO public USING (false);

CREATE POLICY "pos_cashiers_insert_deny_all" ON public.pos_cashiers FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "pos_cashiers_select_deny_all" ON public.pos_cashiers FOR SELECT TO public USING (false);

CREATE POLICY "pos_cashiers_update_deny_all" ON public.pos_cashiers FOR UPDATE TO public USING (false);

CREATE POLICY "Allow authenticated all on pos_discount_policies" ON public.pos_discount_policies FOR ALL USING (true);

CREATE POLICY "Allow public select on pos_discount_policies" ON public.pos_discount_policies FOR SELECT USING (true);

CREATE POLICY "pos_discount_policies_delete_deny_all" ON public.pos_discount_policies FOR DELETE TO public USING (false);

CREATE POLICY "pos_discount_policies_insert_deny_all" ON public.pos_discount_policies FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "pos_discount_policies_select_deny_all" ON public.pos_discount_policies FOR SELECT TO public USING (false);

CREATE POLICY "pos_discount_policies_update_deny_all" ON public.pos_discount_policies FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public insert on pos_item_discount_logs" ON public.pos_item_discount_logs FOR INSERT WITH CHECK (true);

CREATE POLICY "Allow public select on pos_item_discount_logs" ON public.pos_item_discount_logs FOR SELECT USING (true);

CREATE POLICY "pos_item_discount_logs_delete_deny_all" ON public.pos_item_discount_logs FOR DELETE TO public USING (false);

CREATE POLICY "pos_item_discount_logs_insert_deny_all" ON public.pos_item_discount_logs FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "pos_item_discount_logs_select_deny_all" ON public.pos_item_discount_logs FOR SELECT TO public USING (false);

CREATE POLICY "pos_item_discount_logs_update_deny_all" ON public.pos_item_discount_logs FOR UPDATE TO public USING (false);

CREATE POLICY "pos_orders_insert" ON public.pos_orders FOR INSERT WITH CHECK (true);

CREATE POLICY "pos_orders_select" ON public.pos_orders FOR SELECT USING (true);

CREATE POLICY "pos_orders_update" ON public.pos_orders FOR UPDATE USING (true);

CREATE POLICY "Allow public insert pos_table_notifications" ON public.pos_table_notifications FOR INSERT WITH CHECK (true);

CREATE POLICY "Allow public select pos_table_notifications" ON public.pos_table_notifications FOR SELECT USING (true);

CREATE POLICY "Allow public update pos_table_notifications" ON public.pos_table_notifications FOR UPDATE USING (true);

CREATE POLICY "Allow public delete" ON public.pos_tables FOR DELETE USING (true);

CREATE POLICY "Allow public insert" ON public.pos_tables FOR INSERT WITH CHECK (true);

CREATE POLICY "Allow public select" ON public.pos_tables FOR SELECT USING (true);

CREATE POLICY "Allow public update" ON public.pos_tables FOR UPDATE USING (true);

CREATE POLICY "product_addon_groups_delete_deny_all" ON public.product_addon_groups FOR DELETE TO public USING (false);

CREATE POLICY "product_addon_groups_insert_deny_all" ON public.product_addon_groups FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "product_addon_groups_public_select" ON public.product_addon_groups FOR SELECT TO public USING (true);

CREATE POLICY "product_addon_groups_update_deny_all" ON public.product_addon_groups FOR UPDATE TO public USING (false);

CREATE POLICY "product_upgrade_mapping_delete_deny_all" ON public.product_upgrade_mapping FOR DELETE TO public USING (false);

CREATE POLICY "product_upgrade_mapping_insert_deny_all" ON public.product_upgrade_mapping FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "product_upgrade_mapping_public_select" ON public.product_upgrade_mapping FOR SELECT TO public USING (true);

CREATE POLICY "product_upgrade_mapping_update_deny_all" ON public.product_upgrade_mapping FOR UPDATE TO public USING (false);

CREATE POLICY "product_variants_delete_deny_all" ON public.product_variants FOR DELETE TO public USING (false);

CREATE POLICY "product_variants_insert_deny_all" ON public.product_variants FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "product_variants_public_select" ON public.product_variants FOR SELECT TO public USING (true);

CREATE POLICY "product_variants_update_deny_all" ON public.product_variants FOR UPDATE TO public USING (false);

CREATE POLICY "Allow authenticated all on product_version_history" ON public.product_version_history FOR ALL USING (true);

CREATE POLICY "Allow public select on product_version_history" ON public.product_version_history FOR SELECT USING (true);

CREATE POLICY "product_version_history_delete_deny_all" ON public.product_version_history FOR DELETE TO public USING (false);

CREATE POLICY "product_version_history_insert_deny_all" ON public.product_version_history FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "product_version_history_select_deny_all" ON public.product_version_history FOR SELECT TO public USING (false);

CREATE POLICY "product_version_history_update_deny_all" ON public.product_version_history FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete POI" ON public.production_order_items FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert POI" ON public.production_order_items FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select POI" ON public.production_order_items FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update POI" ON public.production_order_items FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "production_order_items_delete_deny_all" ON public.production_order_items FOR DELETE TO public USING (false);

CREATE POLICY "production_order_items_insert_deny_all" ON public.production_order_items FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "production_order_items_select_deny_all" ON public.production_order_items FOR SELECT TO public USING (false);

CREATE POLICY "production_order_items_update_deny_all" ON public.production_order_items FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete PO" ON public.production_orders FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert PO" ON public.production_orders FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select PO" ON public.production_orders FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update PO" ON public.production_orders FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "production_orders_delete_deny_all" ON public.production_orders FOR DELETE TO public USING (false);

CREATE POLICY "production_orders_insert_deny_all" ON public.production_orders FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "production_orders_select_deny_all" ON public.production_orders FOR SELECT TO public USING (false);

CREATE POLICY "production_orders_update_deny_all" ON public.production_orders FOR UPDATE TO public USING (false);

CREATE POLICY "products_delete_deny_all" ON public.products FOR DELETE TO public USING (false);

CREATE POLICY "products_insert_deny_all" ON public.products FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "products_public_select" ON public.products FOR SELECT TO public USING (true);

CREATE POLICY "products_update_deny_all" ON public.products FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete" ON public.purchase_order_items FOR DELETE USING (true);

CREATE POLICY "Allow public insert" ON public.purchase_order_items FOR INSERT WITH CHECK (true);

CREATE POLICY "Allow public select" ON public.purchase_order_items FOR SELECT USING (true);

CREATE POLICY "Allow public update" ON public.purchase_order_items FOR UPDATE USING (true);

CREATE POLICY "purchase_order_items_delete_deny_all" ON public.purchase_order_items FOR DELETE TO public USING (false);

CREATE POLICY "purchase_order_items_insert_deny_all" ON public.purchase_order_items FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "purchase_order_items_select_deny_all" ON public.purchase_order_items FOR SELECT TO public USING (false);

CREATE POLICY "purchase_order_items_update_deny_all" ON public.purchase_order_items FOR UPDATE TO public USING (false);

CREATE POLICY "purchase_orders_delete_deny_all" ON public.purchase_orders FOR DELETE TO public USING (false);

CREATE POLICY "purchase_orders_insert_deny_all" ON public.purchase_orders FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "purchase_orders_select_deny_all" ON public.purchase_orders FOR SELECT TO public USING (false);

CREATE POLICY "purchase_orders_update_deny_all" ON public.purchase_orders FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete" ON public.purchase_requisition_items FOR DELETE USING (true);

CREATE POLICY "Allow public insert" ON public.purchase_requisition_items FOR INSERT WITH CHECK (true);

CREATE POLICY "Allow public select" ON public.purchase_requisition_items FOR SELECT USING (true);

CREATE POLICY "Allow public update" ON public.purchase_requisition_items FOR UPDATE USING (true);

CREATE POLICY "purchase_requisition_items_delete_deny_all" ON public.purchase_requisition_items FOR DELETE TO public USING (false);

CREATE POLICY "purchase_requisition_items_insert_deny_all" ON public.purchase_requisition_items FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "purchase_requisition_items_select_deny_all" ON public.purchase_requisition_items FOR SELECT TO public USING (false);

CREATE POLICY "purchase_requisition_items_update_deny_all" ON public.purchase_requisition_items FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete" ON public.purchase_requisitions FOR DELETE USING (true);

CREATE POLICY "Allow public insert" ON public.purchase_requisitions FOR INSERT WITH CHECK (true);

CREATE POLICY "Allow public select" ON public.purchase_requisitions FOR SELECT USING (true);

CREATE POLICY "Allow public update" ON public.purchase_requisitions FOR UPDATE USING (true);

CREATE POLICY "purchase_requisitions_delete_deny_all" ON public.purchase_requisitions FOR DELETE TO public USING (false);

CREATE POLICY "purchase_requisitions_insert_deny_all" ON public.purchase_requisitions FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "purchase_requisitions_select_deny_all" ON public.purchase_requisitions FOR SELECT TO public USING (false);

CREATE POLICY "purchase_requisitions_update_deny_all" ON public.purchase_requisitions FOR UPDATE TO public USING (false);

CREATE POLICY "pwa_settings_delete_deny_all" ON public.pwa_settings FOR DELETE TO public USING (false);

CREATE POLICY "pwa_settings_insert_deny_all" ON public.pwa_settings FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "pwa_settings_public_select" ON public.pwa_settings FOR SELECT TO public USING (true);

CREATE POLICY "pwa_settings_update_deny_all" ON public.pwa_settings FOR UPDATE TO public USING (false);

CREATE POLICY "recipe_items_delete_deny_all" ON public.recipe_items FOR DELETE TO public USING (false);

CREATE POLICY "recipe_items_insert_deny_all" ON public.recipe_items FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "recipe_items_select_deny_all" ON public.recipe_items FOR SELECT TO public USING (false);

CREATE POLICY "recipe_items_update_deny_all" ON public.recipe_items FOR UPDATE TO public USING (false);

CREATE POLICY "recipe_master_delete_deny_all" ON public.recipe_master FOR DELETE TO public USING (false);

CREATE POLICY "recipe_master_insert_deny_all" ON public.recipe_master FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "recipe_master_select_deny_all" ON public.recipe_master FOR SELECT TO public USING (false);

CREATE POLICY "recipe_master_update_deny_all" ON public.recipe_master FOR UPDATE TO public USING (false);

CREATE POLICY "recipe_steps_delete_deny_all" ON public.recipe_steps FOR DELETE TO public USING (false);

CREATE POLICY "recipe_steps_insert_deny_all" ON public.recipe_steps FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "recipe_steps_select_deny_all" ON public.recipe_steps FOR SELECT TO public USING (false);

CREATE POLICY "recipe_steps_update_deny_all" ON public.recipe_steps FOR UPDATE TO public USING (false);

CREATE POLICY "recipe_versions_delete_deny_all" ON public.recipe_versions FOR DELETE TO public USING (false);

CREATE POLICY "recipe_versions_insert_deny_all" ON public.recipe_versions FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "recipe_versions_select_deny_all" ON public.recipe_versions FOR SELECT TO public USING (false);

CREATE POLICY "recipe_versions_update_deny_all" ON public.recipe_versions FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public insert restaurant_tables" ON public.restaurant_tables FOR INSERT WITH CHECK (true);

CREATE POLICY "Allow public select restaurant_tables" ON public.restaurant_tables FOR SELECT USING (true);

CREATE POLICY "Allow public update restaurant_tables" ON public.restaurant_tables FOR UPDATE USING (true);

CREATE POLICY "role_permissions_delete_deny_all" ON public.role_permissions FOR DELETE TO public USING (false);

CREATE POLICY "role_permissions_insert_deny_all" ON public.role_permissions FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "role_permissions_select_deny_all" ON public.role_permissions FOR SELECT TO public USING (false);

CREATE POLICY "role_permissions_update_deny_all" ON public.role_permissions FOR UPDATE TO public USING (false);

CREATE POLICY "roles_delete_deny_all" ON public.roles FOR DELETE TO public USING (false);

CREATE POLICY "roles_insert_deny_all" ON public.roles FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "roles_select_deny_all" ON public.roles FOR SELECT TO public USING (false);

CREATE POLICY "roles_update_deny_all" ON public.roles FOR UPDATE TO public USING (false);

CREATE POLICY "section_templates_delete_deny_all" ON public.section_templates FOR DELETE TO public USING (false);

CREATE POLICY "section_templates_insert_deny_all" ON public.section_templates FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "section_templates_public_select" ON public.section_templates FOR SELECT TO public USING (true);

CREATE POLICY "section_templates_update_deny_all" ON public.section_templates FOR UPDATE TO public USING (false);

CREATE POLICY "security_alerts_delete_deny_all" ON public.security_alerts FOR DELETE TO public USING (false);

CREATE POLICY "security_alerts_insert" ON public.security_alerts FOR INSERT WITH CHECK (true);

CREATE POLICY "security_alerts_insert_deny_all" ON public.security_alerts FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "security_alerts_select" ON public.security_alerts FOR SELECT USING (public.is_super_admin() OR public.is_admin());

CREATE POLICY "security_alerts_select_deny_all" ON public.security_alerts FOR SELECT TO public USING (false);

CREATE POLICY "security_alerts_update_deny_all" ON public.security_alerts FOR UPDATE TO public USING (false);

CREATE POLICY "security_events_delete_deny_all" ON public.security_events FOR DELETE TO public USING (false);

CREATE POLICY "security_events_insert" ON public.security_events FOR INSERT WITH CHECK (true);

CREATE POLICY "security_events_insert_deny_all" ON public.security_events FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "security_events_select" ON public.security_events FOR SELECT USING (public.is_super_admin());

CREATE POLICY "security_events_select_deny_all" ON public.security_events FOR SELECT TO public USING (false);

CREATE POLICY "security_events_update_deny_all" ON public.security_events FOR UPDATE TO public USING (false);

CREATE POLICY "attendance_insert" ON public.staff_attendance FOR INSERT WITH CHECK (true);

CREATE POLICY "attendance_select" ON public.staff_attendance FOR SELECT USING (true);

CREATE POLICY "attendance_update" ON public.staff_attendance FOR UPDATE USING (true);

CREATE POLICY "modify_staff_attendance" ON public.staff_attendance FOR ALL 
USING (staff_id = public.get_current_user_id() OR public.is_super_admin() OR EXISTS (SELECT 1 FROM public.users u WHERE u.id = public.staff_attendance.staff_id AND u.branch_id = public.get_current_user_branch_id()));

CREATE POLICY "select_staff_attendance" ON public.staff_attendance FOR SELECT 
USING (staff_id = public.get_current_user_id() OR public.is_super_admin() OR EXISTS (SELECT 1 FROM public.users u WHERE u.id = public.staff_attendance.staff_id AND u.branch_id = public.get_current_user_branch_id()));

CREATE POLICY "modify_staff_profiles" ON public.staff_profiles FOR ALL 
USING (public.is_super_admin() OR (public.is_admin() AND EXISTS (SELECT 1 FROM public.users u WHERE u.id = public.staff_profiles.id AND u.branch_id = public.get_current_user_branch_id())));

CREATE POLICY "select_staff_profiles" ON public.staff_profiles FOR SELECT 
USING (public.is_super_admin() OR public.is_admin() OR id = public.get_current_user_id() OR EXISTS (SELECT 1 FROM public.users u WHERE u.id = public.staff_profiles.id AND u.branch_id = public.get_current_user_branch_id()));

CREATE POLICY "Allow public delete" ON public.stock_adjustment_items FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert" ON public.stock_adjustment_items FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select" ON public.stock_adjustment_items FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update" ON public.stock_adjustment_items FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "stock_adjustment_items_delete_deny_all" ON public.stock_adjustment_items FOR DELETE TO public USING (false);

CREATE POLICY "stock_adjustment_items_insert_deny_all" ON public.stock_adjustment_items FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "stock_adjustment_items_select_deny_all" ON public.stock_adjustment_items FOR SELECT TO public USING (false);

CREATE POLICY "stock_adjustment_items_update_deny_all" ON public.stock_adjustment_items FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete" ON public.stock_adjustments FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert" ON public.stock_adjustments FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select" ON public.stock_adjustments FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update" ON public.stock_adjustments FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "stock_adjustments_delete_deny_all" ON public.stock_adjustments FOR DELETE TO public USING (false);

CREATE POLICY "stock_adjustments_insert_deny_all" ON public.stock_adjustments FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "stock_adjustments_select_deny_all" ON public.stock_adjustments FOR SELECT TO public USING (false);

CREATE POLICY "stock_adjustments_update_deny_all" ON public.stock_adjustments FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete" ON public.stock_audit_items FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert" ON public.stock_audit_items FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select" ON public.stock_audit_items FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update" ON public.stock_audit_items FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "stock_audit_items_delete_deny_all" ON public.stock_audit_items FOR DELETE TO public USING (false);

CREATE POLICY "stock_audit_items_insert_deny_all" ON public.stock_audit_items FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "stock_audit_items_select_deny_all" ON public.stock_audit_items FOR SELECT TO public USING (false);

CREATE POLICY "stock_audit_items_update_deny_all" ON public.stock_audit_items FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete" ON public.stock_audits FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert" ON public.stock_audits FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select" ON public.stock_audits FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update" ON public.stock_audits FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "stock_audits_delete_deny_all" ON public.stock_audits FOR DELETE TO public USING (false);

CREATE POLICY "stock_audits_insert_deny_all" ON public.stock_audits FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "stock_audits_select_deny_all" ON public.stock_audits FOR SELECT TO public USING (false);

CREATE POLICY "stock_audits_update_deny_all" ON public.stock_audits FOR UPDATE TO public USING (false);

CREATE POLICY "stock_conversion_rules_delete_deny_all" ON public.stock_conversion_rules FOR DELETE TO public USING (false);

CREATE POLICY "stock_conversion_rules_insert_deny_all" ON public.stock_conversion_rules FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "stock_conversion_rules_select_deny_all" ON public.stock_conversion_rules FOR SELECT TO public USING (false);

CREATE POLICY "stock_conversion_rules_update_deny_all" ON public.stock_conversion_rules FOR UPDATE TO public USING (false);

CREATE POLICY "modify_stock_entries" ON public.stock_entries FOR ALL 
USING (public.is_super_admin() OR EXISTS (SELECT 1 FROM public.users u WHERE u.id = public.get_current_user_id() AND u.branch_id = (SELECT branch_id FROM public.users su WHERE su.id = public.stock_entries.staff_id)));

CREATE POLICY "select_stock_entries" ON public.stock_entries FOR SELECT 
USING (public.is_super_admin() OR public.is_admin() OR EXISTS (SELECT 1 FROM public.users u WHERE u.id = public.stock_entries.staff_id AND u.branch_id = public.get_current_user_branch_id()));

CREATE POLICY "stock_entries_delete_deny_all" ON public.stock_entries FOR DELETE TO public USING (false);

CREATE POLICY "stock_entries_insert_deny_all" ON public.stock_entries FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "stock_entries_select_deny_all" ON public.stock_entries FOR SELECT TO public USING (false);

CREATE POLICY "stock_entries_update_deny_all" ON public.stock_entries FOR UPDATE TO public USING (false);

CREATE POLICY "stock_ledger_delete_deny_all" ON public.stock_ledger FOR DELETE TO public USING (false);

CREATE POLICY "stock_ledger_insert_deny_all" ON public.stock_ledger FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "stock_ledger_select_deny_all" ON public.stock_ledger FOR SELECT TO public USING (false);

CREATE POLICY "stock_ledger_update_deny_all" ON public.stock_ledger FOR UPDATE TO public USING (false);

CREATE POLICY "stock_master_delete_deny_all" ON public.stock_master FOR DELETE TO public USING (false);

CREATE POLICY "stock_master_insert_deny_all" ON public.stock_master FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "stock_master_select_deny_all" ON public.stock_master FOR SELECT TO public USING (false);

CREATE POLICY "stock_master_update_deny_all" ON public.stock_master FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete" ON public.stock_transfer_items FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert" ON public.stock_transfer_items FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select" ON public.stock_transfer_items FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update" ON public.stock_transfer_items FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "stock_transfer_items_delete_deny_all" ON public.stock_transfer_items FOR DELETE TO public USING (false);

CREATE POLICY "stock_transfer_items_insert_deny_all" ON public.stock_transfer_items FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "stock_transfer_items_select_deny_all" ON public.stock_transfer_items FOR SELECT TO public USING (false);

CREATE POLICY "stock_transfer_items_update_deny_all" ON public.stock_transfer_items FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete" ON public.stock_transfers FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert" ON public.stock_transfers FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select" ON public.stock_transfers FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update" ON public.stock_transfers FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "stock_transfers_delete_deny_all" ON public.stock_transfers FOR DELETE TO public USING (false);

CREATE POLICY "stock_transfers_insert_deny_all" ON public.stock_transfers FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "stock_transfers_select_deny_all" ON public.stock_transfers FOR SELECT TO public USING (false);

CREATE POLICY "stock_transfers_update_deny_all" ON public.stock_transfers FOR UPDATE TO public USING (false);

CREATE POLICY "sub_categories_delete_deny_all" ON public.sub_categories FOR DELETE TO public USING (false);

CREATE POLICY "sub_categories_insert_deny_all" ON public.sub_categories FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "sub_categories_public_select" ON public.sub_categories FOR SELECT TO public USING (true);

CREATE POLICY "sub_categories_update_deny_all" ON public.sub_categories FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete" ON public.supplier_addresses FOR DELETE USING (true);

CREATE POLICY "Allow public insert" ON public.supplier_addresses FOR INSERT WITH CHECK (true);

CREATE POLICY "Allow public select" ON public.supplier_addresses FOR SELECT USING (true);

CREATE POLICY "Allow public update" ON public.supplier_addresses FOR UPDATE USING (true);

CREATE POLICY "supplier_addresses_delete_deny_all" ON public.supplier_addresses FOR DELETE TO public USING (false);

CREATE POLICY "supplier_addresses_insert_deny_all" ON public.supplier_addresses FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "supplier_addresses_select_deny_all" ON public.supplier_addresses FOR SELECT TO public USING (false);

CREATE POLICY "supplier_addresses_update_deny_all" ON public.supplier_addresses FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete" ON public.supplier_contacts FOR DELETE USING (true);

CREATE POLICY "Allow public insert" ON public.supplier_contacts FOR INSERT WITH CHECK (true);

CREATE POLICY "Allow public select" ON public.supplier_contacts FOR SELECT USING (true);

CREATE POLICY "Allow public update" ON public.supplier_contacts FOR UPDATE USING (true);

CREATE POLICY "supplier_contacts_delete_deny_all" ON public.supplier_contacts FOR DELETE TO public USING (false);

CREATE POLICY "supplier_contacts_insert_deny_all" ON public.supplier_contacts FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "supplier_contacts_select_deny_all" ON public.supplier_contacts FOR SELECT TO public USING (false);

CREATE POLICY "supplier_contacts_update_deny_all" ON public.supplier_contacts FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete" ON public.supplier_documents FOR DELETE USING (true);

CREATE POLICY "Allow public insert" ON public.supplier_documents FOR INSERT WITH CHECK (true);

CREATE POLICY "Allow public select" ON public.supplier_documents FOR SELECT USING (true);

CREATE POLICY "Allow public update" ON public.supplier_documents FOR UPDATE USING (true);

CREATE POLICY "supplier_documents_delete_deny_all" ON public.supplier_documents FOR DELETE TO public USING (false);

CREATE POLICY "supplier_documents_insert_deny_all" ON public.supplier_documents FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "supplier_documents_select_deny_all" ON public.supplier_documents FOR SELECT TO public USING (false);

CREATE POLICY "supplier_documents_update_deny_all" ON public.supplier_documents FOR UPDATE TO public USING (false);

CREATE POLICY "supplier_ingredient_prices_delete_deny_all" ON public.supplier_ingredient_prices FOR DELETE TO public USING (false);

CREATE POLICY "supplier_ingredient_prices_insert_deny_all" ON public.supplier_ingredient_prices FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "supplier_ingredient_prices_select_deny_all" ON public.supplier_ingredient_prices FOR SELECT TO public USING (false);

CREATE POLICY "supplier_ingredient_prices_update_deny_all" ON public.supplier_ingredient_prices FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete" ON public.supplier_price_history FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert" ON public.supplier_price_history FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select" ON public.supplier_price_history FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update" ON public.supplier_price_history FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "supplier_price_history_delete_deny_all" ON public.supplier_price_history FOR DELETE TO public USING (false);

CREATE POLICY "supplier_price_history_insert_deny_all" ON public.supplier_price_history FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "supplier_price_history_select_deny_all" ON public.supplier_price_history FOR SELECT TO public USING (false);

CREATE POLICY "supplier_price_history_update_deny_all" ON public.supplier_price_history FOR UPDATE TO public USING (false);

CREATE POLICY "suppliers_delete_deny_all" ON public.suppliers FOR DELETE TO public USING (false);

CREATE POLICY "suppliers_insert_deny_all" ON public.suppliers FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "suppliers_select_deny_all" ON public.suppliers FOR SELECT TO public USING (false);

CREATE POLICY "suppliers_update_deny_all" ON public.suppliers FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete support_tickets" ON public.support_tickets FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert support_tickets" ON public.support_tickets FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select support_tickets" ON public.support_tickets FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update support_tickets" ON public.support_tickets FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "support_tickets_delete_deny_all" ON public.support_tickets FOR DELETE TO public USING (false);

CREATE POLICY "support_tickets_insert_deny_all" ON public.support_tickets FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "support_tickets_select_deny_all" ON public.support_tickets FOR SELECT TO public USING (false);

CREATE POLICY "support_tickets_update_deny_all" ON public.support_tickets FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete" ON public.system_audit_logs FOR DELETE USING (true);

CREATE POLICY "Allow public insert" ON public.system_audit_logs FOR INSERT WITH CHECK (true);

CREATE POLICY "Allow public select" ON public.system_audit_logs FOR SELECT USING (true);

CREATE POLICY "Allow public update" ON public.system_audit_logs FOR UPDATE USING (true);

CREATE POLICY "Select audit logs" ON public.system_audit_logs FOR SELECT USING (true);

CREATE POLICY "system_audit_logs_delete_deny_all" ON public.system_audit_logs FOR DELETE TO public USING (false);

CREATE POLICY "system_audit_logs_insert" ON public.system_audit_logs FOR INSERT WITH CHECK (true);

CREATE POLICY "system_audit_logs_insert_deny_all" ON public.system_audit_logs FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "system_audit_logs_select" ON public.system_audit_logs FOR SELECT USING (public.is_super_admin());

CREATE POLICY "system_audit_logs_select_deny_all" ON public.system_audit_logs FOR SELECT TO public USING (false);

CREATE POLICY "system_audit_logs_update_deny_all" ON public.system_audit_logs FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public insert table_sessions" ON public.table_sessions FOR INSERT WITH CHECK (true);

CREATE POLICY "Allow public select table_sessions" ON public.table_sessions FOR SELECT USING (true);

CREATE POLICY "Allow public update table_sessions" ON public.table_sessions FOR UPDATE USING (true);

CREATE POLICY "Allow public delete" ON public.task_dependencies FOR DELETE USING (true);

CREATE POLICY "Allow public insert" ON public.task_dependencies FOR INSERT WITH CHECK (true);

CREATE POLICY "Allow public select" ON public.task_dependencies FOR SELECT USING (true);

CREATE POLICY "Allow public update" ON public.task_dependencies FOR UPDATE USING (true);

CREATE POLICY "task_dependencies_delete_deny_all" ON public.task_dependencies FOR DELETE TO public USING (false);

CREATE POLICY "task_dependencies_insert_deny_all" ON public.task_dependencies FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "task_dependencies_select_deny_all" ON public.task_dependencies FOR SELECT TO public USING (false);

CREATE POLICY "task_dependencies_update_deny_all" ON public.task_dependencies FOR UPDATE TO public USING (false);

CREATE POLICY "units_master_delete_deny_all" ON public.units_master FOR DELETE TO public USING (false);

CREATE POLICY "units_master_insert_deny_all" ON public.units_master FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "units_master_select_deny_all" ON public.units_master FOR SELECT TO public USING (false);

CREATE POLICY "units_master_update_deny_all" ON public.units_master FOR UPDATE TO public USING (false);

CREATE POLICY "user_permissions_delete_deny_all" ON public.user_permissions FOR DELETE TO public USING (false);

CREATE POLICY "user_permissions_insert_deny_all" ON public.user_permissions FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "user_permissions_select_deny_all" ON public.user_permissions FOR SELECT TO public USING (false);

CREATE POLICY "user_permissions_update_deny_all" ON public.user_permissions FOR UPDATE TO public USING (false);

CREATE POLICY "user_profiles_delete_deny_all" ON public.user_profiles FOR DELETE TO public USING (false);

CREATE POLICY "user_profiles_insert_deny_all" ON public.user_profiles FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "user_profiles_select_deny_all" ON public.user_profiles FOR SELECT TO public USING (false);

CREATE POLICY "user_profiles_update_deny_all" ON public.user_profiles FOR UPDATE TO public USING (false);

CREATE POLICY "user_rewards_delete_deny_all" ON public.user_rewards FOR DELETE TO public USING (false);

CREATE POLICY "user_rewards_insert_deny_all" ON public.user_rewards FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "user_rewards_select_deny_all" ON public.user_rewards FOR SELECT TO public USING (false);

CREATE POLICY "user_rewards_update_deny_all" ON public.user_rewards FOR UPDATE TO public USING (false);

CREATE POLICY "Allow select user_roles" ON public.user_roles 
FOR SELECT USING (true);

CREATE POLICY "user_roles_delete_deny_all" ON public.user_roles FOR DELETE TO public USING (false);

CREATE POLICY "user_roles_insert_deny_all" ON public.user_roles FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "user_roles_select_deny_all" ON public.user_roles FOR SELECT TO public USING (false);

CREATE POLICY "user_roles_update_deny_all" ON public.user_roles FOR UPDATE TO public USING (false);

CREATE POLICY "Allow anon insert" ON public.users FOR INSERT WITH CHECK (role = 'customer' OR role IS NULL OR public.is_super_admin() OR public.is_admin());

CREATE POLICY "Allow anon select" ON public.users FOR SELECT USING (true);

CREATE POLICY "Allow matching update" ON public.users FOR UPDATE 
USING (id = public.get_current_user_id() OR public.is_super_admin() OR (public.is_admin() AND public.check_row_branch_access(branch_id)))
WITH CHECK (id = public.get_current_user_id() OR public.is_super_admin() OR (public.is_admin() AND public.check_row_branch_access(branch_id)));

CREATE POLICY "Allow public delete" ON public.vendor_ledger FOR DELETE USING (true);

CREATE POLICY "Allow public insert" ON public.vendor_ledger FOR INSERT WITH CHECK (true);

CREATE POLICY "Allow public select" ON public.vendor_ledger FOR SELECT USING (true);

CREATE POLICY "Allow public update" ON public.vendor_ledger FOR UPDATE USING (true);

CREATE POLICY "vendor_ledger_delete_deny_all" ON public.vendor_ledger FOR DELETE TO public USING (false);

CREATE POLICY "vendor_ledger_insert_deny_all" ON public.vendor_ledger FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "vendor_ledger_select_deny_all" ON public.vendor_ledger FOR SELECT TO public USING (false);

CREATE POLICY "vendor_ledger_update_deny_all" ON public.vendor_ledger FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete" ON public.warehouse_stock FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert" ON public.warehouse_stock FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select" ON public.warehouse_stock FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update" ON public.warehouse_stock FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "warehouse_stock_delete_deny_all" ON public.warehouse_stock FOR DELETE TO public USING (false);

CREATE POLICY "warehouse_stock_insert_deny_all" ON public.warehouse_stock FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "warehouse_stock_select_deny_all" ON public.warehouse_stock FOR SELECT TO public USING (false);

CREATE POLICY "warehouse_stock_update_deny_all" ON public.warehouse_stock FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete" ON public.warehouses FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert" ON public.warehouses FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select" ON public.warehouses FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update" ON public.warehouses FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "warehouses_delete_deny_all" ON public.warehouses FOR DELETE TO public USING (false);

CREATE POLICY "warehouses_insert_deny_all" ON public.warehouses FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "warehouses_select_deny_all" ON public.warehouses FOR SELECT TO public USING (false);

CREATE POLICY "warehouses_update_deny_all" ON public.warehouses FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete" ON public.wastage_items FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert" ON public.wastage_items FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select" ON public.wastage_items FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update" ON public.wastage_items FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "wastage_items_delete_deny_all" ON public.wastage_items FOR DELETE TO public USING (false);

CREATE POLICY "wastage_items_insert_deny_all" ON public.wastage_items FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "wastage_items_select_deny_all" ON public.wastage_items FOR SELECT TO public USING (false);

CREATE POLICY "wastage_items_update_deny_all" ON public.wastage_items FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete" ON public.wastage_records FOR DELETE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public insert" ON public.wastage_records FOR INSERT WITH CHECK (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public select" ON public.wastage_records FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update" ON public.wastage_records FOR UPDATE USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "wastage_records_delete_deny_all" ON public.wastage_records FOR DELETE TO public USING (false);

CREATE POLICY "wastage_records_insert_deny_all" ON public.wastage_records FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "wastage_records_select_deny_all" ON public.wastage_records FOR SELECT TO public USING (false);

CREATE POLICY "wastage_records_update_deny_all" ON public.wastage_records FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete white_label_configs" ON public.white_label_configs FOR DELETE USING (public.is_super_admin());

CREATE POLICY "Allow public insert white_label_configs" ON public.white_label_configs FOR INSERT WITH CHECK (public.is_super_admin());

CREATE POLICY "Allow public select white_label_configs" ON public.white_label_configs FOR SELECT USING (true);

CREATE POLICY "Allow public update white_label_configs" ON public.white_label_configs FOR UPDATE USING (public.is_super_admin());

CREATE POLICY "white_label_configs_delete_deny_all" ON public.white_label_configs FOR DELETE TO public USING (false);

CREATE POLICY "white_label_configs_insert_deny_all" ON public.white_label_configs FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "white_label_configs_public_select" ON public.white_label_configs FOR SELECT TO public USING (true);

CREATE POLICY "white_label_configs_update_deny_all" ON public.white_label_configs FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete workflow_conditions" ON public.workflow_conditions FOR DELETE USING (public.is_super_admin() OR public.has_permission('workflow.approve'));

CREATE POLICY "Allow public insert workflow_conditions" ON public.workflow_conditions FOR INSERT WITH CHECK (public.is_super_admin() OR public.has_permission('workflow.approve'));

CREATE POLICY "Allow public select workflow_conditions" ON public.workflow_conditions FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update workflow_conditions" ON public.workflow_conditions FOR UPDATE USING (public.is_super_admin() OR public.has_permission('workflow.approve'));

CREATE POLICY "workflow_conditions_delete_deny_all" ON public.workflow_conditions FOR DELETE TO public USING (false);

CREATE POLICY "workflow_conditions_insert_deny_all" ON public.workflow_conditions FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "workflow_conditions_select_deny_all" ON public.workflow_conditions FOR SELECT TO public USING (false);

CREATE POLICY "workflow_conditions_update_deny_all" ON public.workflow_conditions FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete workflow_definitions" ON public.workflow_definitions FOR DELETE USING (public.is_super_admin() OR public.has_permission('workflow.approve'));

CREATE POLICY "Allow public insert workflow_definitions" ON public.workflow_definitions FOR INSERT WITH CHECK (public.is_super_admin() OR public.has_permission('workflow.approve'));

CREATE POLICY "Allow public select workflow_definitions" ON public.workflow_definitions FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update workflow_definitions" ON public.workflow_definitions FOR UPDATE USING (public.is_super_admin() OR public.has_permission('workflow.approve'));

CREATE POLICY "workflow_definitions_delete_deny_all" ON public.workflow_definitions FOR DELETE TO public USING (false);

CREATE POLICY "workflow_definitions_insert_deny_all" ON public.workflow_definitions FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "workflow_definitions_select_deny_all" ON public.workflow_definitions FOR SELECT TO public USING (false);

CREATE POLICY "workflow_definitions_update_deny_all" ON public.workflow_definitions FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete workflow_history" ON public.workflow_history FOR DELETE USING (public.is_super_admin() OR public.has_permission('workflow.approve'));

CREATE POLICY "Allow public insert workflow_history" ON public.workflow_history FOR INSERT WITH CHECK (public.is_super_admin() OR public.has_permission('workflow.approve'));

CREATE POLICY "Allow public select workflow_history" ON public.workflow_history FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update workflow_history" ON public.workflow_history FOR UPDATE USING (public.is_super_admin() OR public.has_permission('workflow.approve'));

CREATE POLICY "workflow_history_delete_deny_all" ON public.workflow_history FOR DELETE TO public USING (false);

CREATE POLICY "workflow_history_insert_deny_all" ON public.workflow_history FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "workflow_history_select_deny_all" ON public.workflow_history FOR SELECT TO public USING (false);

CREATE POLICY "workflow_history_update_deny_all" ON public.workflow_history FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete workflow_instances" ON public.workflow_instances FOR DELETE USING (public.is_super_admin() OR public.has_permission('workflow.approve'));

CREATE POLICY "Allow public insert workflow_instances" ON public.workflow_instances FOR INSERT WITH CHECK (public.is_super_admin() OR public.has_permission('workflow.approve'));

CREATE POLICY "Allow public select workflow_instances" ON public.workflow_instances FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update workflow_instances" ON public.workflow_instances FOR UPDATE USING (public.is_super_admin() OR public.has_permission('workflow.approve'));

CREATE POLICY "workflow_instances_delete_deny_all" ON public.workflow_instances FOR DELETE TO public USING (false);

CREATE POLICY "workflow_instances_insert_deny_all" ON public.workflow_instances FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "workflow_instances_select_deny_all" ON public.workflow_instances FOR SELECT TO public USING (false);

CREATE POLICY "workflow_instances_update_deny_all" ON public.workflow_instances FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete workflow_steps" ON public.workflow_steps FOR DELETE USING (public.is_super_admin() OR public.has_permission('workflow.approve'));

CREATE POLICY "Allow public insert workflow_steps" ON public.workflow_steps FOR INSERT WITH CHECK (public.is_super_admin() OR public.has_permission('workflow.approve'));

CREATE POLICY "Allow public select workflow_steps" ON public.workflow_steps FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update workflow_steps" ON public.workflow_steps FOR UPDATE USING (public.is_super_admin() OR public.has_permission('workflow.approve'));

CREATE POLICY "workflow_steps_delete_deny_all" ON public.workflow_steps FOR DELETE TO public USING (false);

CREATE POLICY "workflow_steps_insert_deny_all" ON public.workflow_steps FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "workflow_steps_select_deny_all" ON public.workflow_steps FOR SELECT TO public USING (false);

CREATE POLICY "workflow_steps_update_deny_all" ON public.workflow_steps FOR UPDATE TO public USING (false);

CREATE POLICY "Allow public delete workflow_tasks" ON public.workflow_tasks FOR DELETE USING (public.is_super_admin() OR public.has_permission('workflow.approve'));

CREATE POLICY "Allow public insert workflow_tasks" ON public.workflow_tasks FOR INSERT WITH CHECK (public.is_super_admin() OR public.has_permission('workflow.approve'));

CREATE POLICY "Allow public select workflow_tasks" ON public.workflow_tasks FOR SELECT USING (public.get_current_user_id() IS NOT NULL);

CREATE POLICY "Allow public update workflow_tasks" ON public.workflow_tasks FOR UPDATE USING (public.is_super_admin() OR public.has_permission('workflow.approve'));

CREATE POLICY "workflow_tasks_delete_deny_all" ON public.workflow_tasks FOR DELETE TO public USING (false);

CREATE POLICY "workflow_tasks_insert_deny_all" ON public.workflow_tasks FOR INSERT TO public WITH CHECK (false);

CREATE POLICY "workflow_tasks_select_deny_all" ON public.workflow_tasks FOR SELECT TO public USING (false);

CREATE POLICY "workflow_tasks_update_deny_all" ON public.workflow_tasks FOR UPDATE TO public USING (false);


-- Explicit RPC Grants
GRANT EXECUTE ON FUNCTION public._build_qr_order_accepted_response TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public._ready_inventory_authorize TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public._ready_inventory_deduct_pos_sale TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public._ready_inventory_deduct_website_sale TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public._ready_inventory_mapping_variant_guard TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public._ready_inventory_movements_immutable TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.block_direct_writes TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.calculate_distance_km TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.check_and_trigger_reorder TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.check_row_branch_access TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.cleanup_stale_sessions TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.convert_units TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.deduct_inventory_stock TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.deduct_recipe_item TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.enforce_finalized_po_immutability TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.enforce_po_items_immutability TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.exec_sql TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.generate_supplier_code TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.get_current_session_token TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.get_current_user_branch_id TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.get_current_user_email_or_system TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.get_current_user_id TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.get_current_user_roles TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.get_erp_health_metrics TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.handle_delivery_reservation_lifecycle TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.handle_delivery_settlement_accounting TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.handle_eip_event_bus_logging TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.handle_grn_completed_accounting TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.handle_iam_modification_audit TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.handle_order_coins_trigger TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.handle_pos_reservation_lifecycle TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.handle_pos_sales_accounting TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.handle_rider_cash_collection TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.handle_vendor_payment_accounting TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.handle_wastage_accounting TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.has_permission TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.is_admin TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.is_super_admin TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.log_attendance_out_of_bounds_alert TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.on_user_created_provision_wallet TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.post_journal_entry TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.process_delivery_order_completed_stock TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.process_grn_completion TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.process_pos_order_completed_stock TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.process_production_completion TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.recalculate_recipe_costs_for_ingredient TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_accept_qr_order TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_activate_migrated_customer TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_adjust_inventory TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_assign_multi_role TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_assign_user_role TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_cancel_delivery_order TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_cancel_pending_payment_order TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_cancel_pos_order TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_change_table_session TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_check_customer_exists TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_check_permission TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_clear_pos_notification_history TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_confirm_online_refund TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_confirm_order_payment TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_create_internal_user TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_create_order TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_credit_manual_coins TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_customer_login TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_customer_signup TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_delete_customer_address TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_delete_user TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_fail_order_payment TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_force_reset_table TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_get_active_pos_order_item_signatures TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_get_active_sessions_admin TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_get_customer_account_state TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_get_customer_addresses TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_get_customer_order_details TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_get_customer_orders TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_get_customer_profile TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_get_customer_qr_order_status TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_get_customer_table_requests TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_get_delivery_order_items_admin TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_get_delivery_orders_admin TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_get_kot_corrections_admin TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_get_kot_corrections_for_order TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_get_kot_print_state TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_get_kots_for_order TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_get_or_create_customer_session TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_get_pay_transactions_admin TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_get_pos_customer TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_get_pos_notifications TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_get_pos_order_audit_history TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_get_pos_order_items_admin TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_get_pos_order_items_report_admin TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_get_pos_orders_admin TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_get_pos_orders_report_admin TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_get_pos_qr_pending_admin TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_get_pos_tables TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_get_qr_guest_name TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_get_qr_session_status TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_get_security_report TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_get_session TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_get_table_sessions_admin TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_get_website_order_items_report_admin TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_get_website_orders_admin TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_get_website_orders_report_admin TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_increment_payment_attempt TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_initiate_online_refund TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_initiate_retry_payment TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_internal_login TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_list_customers_admin TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_list_internal_users TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_log_audit TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_manage_choice_group TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_manage_offer_admin TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_manage_qr_table_config TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_manual_verify_payment TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_ready_inventory_adjust TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_ready_inventory_disconnect_mapping TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_ready_inventory_list_items TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_ready_inventory_list_mappings TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_ready_inventory_list_menu_products TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_ready_inventory_list_movements TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_ready_inventory_save_item TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_ready_inventory_save_mapping TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_record_manual_pos_refund TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_recover_orphaned_pos_table TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_redeem_pos_wallet TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_reject_qr_order TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_reject_website_order TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_release_pos_table TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_report_kot_print_result TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_reset_user_credentials TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_resolve_alert TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_save_category TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_save_customer_address TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_save_kot_correction TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_save_kot_event TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_save_product TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_settle_pos_order TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_staff_check_in TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_staff_check_out TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_start_qr_table_session TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_start_table_session TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_submit_customer_table_request TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_submit_qr_table_order TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_sync_pos_order TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_terminate_all_sessions TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_terminate_session TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_terminate_user_sessions TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_toggle_user_status TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_toggle_wallet_freeze TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_touch_session TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_transition_live_order TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_update_customer_profile TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_update_delivery_settings TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_update_order_status TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_update_pos_customer_name TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_update_pos_notification_status TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_validate_coupon TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_validate_qr_table_access TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_verify_qr_table_reentry TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.secure_void_table_session TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.sync_account_balances TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.sync_inventory_topup_stock TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.sync_staff_profiles_delete TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.sync_staff_profiles_insert TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.sync_staff_profiles_update TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.sync_users_legacy_fields TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.sync_users_to_staff_profiles TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.temp_list_staff_profiles TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.temp_list_tables TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.to TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.update_updated_at_column TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.validate_active_session_internal TO authenticated, anon;
