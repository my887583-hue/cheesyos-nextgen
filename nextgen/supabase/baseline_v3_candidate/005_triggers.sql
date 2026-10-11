-- CHEESYOS NEXTGEN BASELINE V3 CANDIDATE: TRIGGERS
-- Target Project: sdbnibyzqtgpbexlznat

CREATE TRIGGER trg_sync_users_legacy_fields
BEFORE INSERT OR UPDATE ON public.users
FOR EACH ROW EXECUTE FUNCTION public.sync_users_legacy_fields();

CREATE TRIGGER trg_block_direct_writes_wallets
BEFORE INSERT OR UPDATE OR DELETE ON public.cheesy_wallets
FOR EACH ROW EXECUTE FUNCTION public.block_direct_writes();

CREATE TRIGGER trg_block_direct_writes_orders
BEFORE INSERT OR UPDATE OR DELETE ON public.orders
FOR EACH ROW EXECUTE FUNCTION public.block_direct_writes();

CREATE TRIGGER trg_log_attendance_out_of_bounds_alert
AFTER INSERT OR UPDATE ON public.staff_attendance
FOR EACH ROW EXECUTE FUNCTION public.log_attendance_out_of_bounds_alert();

CREATE TRIGGER trg_on_user_created_provision_wallet
AFTER INSERT ON public.users
FOR EACH ROW EXECUTE FUNCTION public.on_user_created_provision_wallet();

CREATE TRIGGER trg_orders_coins_handler
BEFORE INSERT OR UPDATE ON public.orders
FOR EACH ROW EXECUTE FUNCTION public.handle_order_coins_trigger();

CREATE TRIGGER trg_pos_orders_coins_handler
BEFORE INSERT OR UPDATE ON public.pos_orders
FOR EACH ROW EXECUTE FUNCTION public.handle_order_coins_trigger();

CREATE TRIGGER trg_cleanup_stale_sessions
BEFORE INSERT ON public.active_sessions
FOR EACH ROW EXECUTE FUNCTION public.cleanup_stale_sessions();

CREATE TRIGGER trg_sync_staff_profiles_insert
BEFORE INSERT ON public.staff_profiles
FOR EACH ROW EXECUTE FUNCTION public.sync_staff_profiles_insert();

CREATE TRIGGER trg_sync_staff_profiles_update
AFTER UPDATE ON public.staff_profiles
FOR EACH ROW EXECUTE FUNCTION public.sync_staff_profiles_update();

CREATE TRIGGER trg_sync_staff_profiles_delete
AFTER DELETE ON public.staff_profiles
FOR EACH ROW EXECUTE FUNCTION public.sync_staff_profiles_delete();

CREATE TRIGGER trg_sync_inventory_topups
AFTER INSERT OR UPDATE OR DELETE ON public.inventory_topups
FOR EACH ROW EXECUTE FUNCTION public.sync_inventory_topup_stock();

CREATE TRIGGER trg_sync_users_to_staff_profiles
AFTER INSERT OR UPDATE ON public.users
FOR EACH ROW EXECUTE FUNCTION public.sync_users_to_staff_profiles();

CREATE TRIGGER trg_delivery_orders_coins_handler
BEFORE UPDATE ON public.delivery_orders
FOR EACH ROW EXECUTE FUNCTION public.handle_order_coins_trigger();

CREATE TRIGGER trg_sync_order_statuses
BEFORE INSERT OR UPDATE ON public.orders
FOR EACH ROW
EXECUTE FUNCTION public.sync_order_statuses();

CREATE TRIGGER trg_generate_supplier_code
BEFORE INSERT ON public.suppliers
FOR EACH ROW EXECUTE FUNCTION public.generate_supplier_code();

CREATE TRIGGER trg_enforce_finalized_po_immutability
BEFORE UPDATE ON public.purchase_orders
FOR EACH ROW EXECUTE FUNCTION public.enforce_finalized_po_immutability();

CREATE TRIGGER trg_enforce_po_items_immutability
BEFORE INSERT OR UPDATE OR DELETE ON public.purchase_order_items
FOR EACH ROW EXECUTE FUNCTION public.enforce_po_items_immutability();

CREATE TRIGGER trg_pos_order_completed_stock
BEFORE UPDATE ON public.pos_orders
FOR EACH ROW EXECUTE FUNCTION public.process_pos_order_completed_stock();

CREATE TRIGGER trg_delivery_order_completed_stock
BEFORE UPDATE ON public.orders
FOR EACH ROW EXECUTE FUNCTION public.process_delivery_order_completed_stock();

CREATE TRIGGER trg_pos_reservation_lifecycle
BEFORE INSERT OR UPDATE ON public.pos_orders
FOR EACH ROW EXECUTE FUNCTION public.handle_pos_reservation_lifecycle();

CREATE TRIGGER trg_delivery_reservation_lifecycle
BEFORE INSERT OR UPDATE ON public.orders
FOR EACH ROW EXECUTE FUNCTION public.handle_delivery_reservation_lifecycle();

CREATE TRIGGER trg_sync_account_balances
AFTER INSERT OR UPDATE OR DELETE ON public.journal_lines
FOR EACH ROW EXECUTE FUNCTION public.sync_account_balances();

CREATE TRIGGER trg_grn_completed_accounting
AFTER UPDATE ON public.grns
FOR EACH ROW EXECUTE FUNCTION public.handle_grn_completed_accounting();

CREATE TRIGGER trg_vendor_payment_accounting
AFTER INSERT ON public.vendor_ledger
FOR EACH ROW EXECUTE FUNCTION public.handle_vendor_payment_accounting();

CREATE TRIGGER trg_pos_sales_accounting
AFTER UPDATE ON public.pos_orders
FOR EACH ROW EXECUTE FUNCTION public.handle_pos_sales_accounting();

CREATE TRIGGER trg_wastage_accounting
AFTER UPDATE ON public.wastage_records
FOR EACH ROW EXECUTE FUNCTION public.handle_wastage_accounting();

CREATE TRIGGER trg_rider_cash_collection
AFTER UPDATE ON public.delivery_orders
FOR EACH ROW EXECUTE FUNCTION public.handle_rider_cash_collection();

CREATE TRIGGER trg_delivery_settlement_accounting
AFTER UPDATE ON public.delivery_cash_settlements
FOR EACH ROW EXECUTE FUNCTION public.handle_delivery_settlement_accounting();

CREATE TRIGGER trg_eip_event_bus_logging
AFTER INSERT ON public.eip_event_bus
FOR EACH ROW EXECUTE FUNCTION public.handle_eip_event_bus_logging();

CREATE TRIGGER trg_iam_role_audit
AFTER INSERT OR UPDATE ON public.iam_roles
FOR EACH ROW EXECUTE FUNCTION public.handle_iam_modification_audit();

CREATE TRIGGER trg_iam_permission_audit
AFTER INSERT OR UPDATE ON public.iam_permissions
FOR EACH ROW EXECUTE FUNCTION public.handle_iam_modification_audit();

CREATE TRIGGER trg_update_choice_groups_updated_at BEFORE UPDATE ON public.choice_groups FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER trg_update_choice_group_products_updated_at BEFORE UPDATE ON public.choice_group_products FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER trg_update_meal_templates_updated_at BEFORE UPDATE ON public.meal_templates FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER trg_update_meal_template_groups_updated_at BEFORE UPDATE ON public.meal_template_groups FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER trg_update_meal_included_products_updated_at BEFORE UPDATE ON public.meal_included_products FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER trg_update_meal_product_versions_updated_at BEFORE UPDATE ON public.meal_product_versions FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER trg_update_meal_product_upgrade_rules_updated_at BEFORE UPDATE ON public.meal_product_upgrade_rules FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER trg_ready_inventory_movements_immutable
BEFORE UPDATE OR DELETE ON public.ready_inventory_movements
FOR EACH ROW EXECUTE FUNCTION public._ready_inventory_movements_immutable();

CREATE TRIGGER trg_ready_inventory_mapping_variant_guard
BEFORE INSERT OR UPDATE ON public.ready_inventory_menu_mappings
FOR EACH ROW EXECUTE FUNCTION public._ready_inventory_mapping_variant_guard();

