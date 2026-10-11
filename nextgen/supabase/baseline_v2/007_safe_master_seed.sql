-- CHEESYOS NEXTGEN BASELINE V2: SAFE MASTER SEED
-- Target Project: sdbnibyzqtgpbexlznat
-- Zero Customer Data | Zero Order Data | Zero Payment Data

INSERT INTO public.iam_roles (id, role_name, description) VALUES
(1, 'Admin', 'Full operational and financial management authority'),
(2, 'Manager', 'Store manager with discount approval authority'),
(3, 'Cashier', 'POS cashier for order booking, billing, and settlements'),
(4, 'Kitchen', 'KDS display monitor and order preparation'),
(5, 'Rider', 'Delivery dispatcher and rider tracker')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.pos_tables (id, name, table_number, capacity, status) VALUES
(1, 'Table 1', '1', 4, 'available'),
(2, 'Table 2', '2', 4, 'available'),
(3, 'Table 3', '3', 4, 'available'),
(4, 'Table 4', '4', 4, 'available'),
(5, 'Table 5', '5', 4, 'available'),
(6, 'Table 6', '6', 4, 'available'),
(7, 'Table 7', '7', 4, 'available'),
(8, 'Table 8', '8', 4, 'available'),
(9, 'Table 9', '9', 4, 'available'),
(10, 'Table 10', '10', 4, 'available')
ON CONFLICT (id) DO NOTHING;
