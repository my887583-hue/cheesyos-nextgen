-- CHEESYOS NEXTGEN BASELINE V2: CONSTRAINTS & INDEXES
-- Target Project: sdbnibyzqtgpbexlznat

CREATE INDEX IF NOT EXISTS idx_pos_orders_status ON public.orders(status);
CREATE INDEX IF NOT EXISTS idx_pos_order_items_order_id ON public.pos_order_items(order_id);
CREATE INDEX IF NOT EXISTS idx_table_sessions_status ON public.table_sessions(status);
CREATE INDEX IF NOT EXISTS idx_pos_kots_order_id ON public.pos_kots(order_id);
