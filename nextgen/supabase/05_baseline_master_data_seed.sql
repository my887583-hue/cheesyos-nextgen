-- CHEESYOS NEXTGEN BASELINE MIGRATION 05: MASTER CATALOG & POS TABLE SEED
-- Target Project: sdbnibyzqtgpbexlznat
-- Generated: 2026-10-10

-- Seed POS Floor Tables
INSERT INTO public.pos_tables (id, name, table_number, capacity, status) VALUES
(1, 'Table 1', 'Table 1', 4, 'available'),
(2, 'Table 2', 'Table 2', 4, 'available'),
(3, 'Table 3', 'Table 3', 4, 'available'),
(6, 'Table 4', 'Table 4', 4, 'available'),
(7, 'Table 5', 'Table 5', 4, 'available'),
(8, 'C 1', 'C 1', 4, 'available'),
(9, 'C2', 'C2', 4, 'available'),
(10, 'PS 1', 'PS 1', 4, 'available'),
(11, 'PS 2', 'PS 2', 4, 'available'),
(12, 'PACK 1', 'PACK 1', 4, 'available'),
(13, 'PACK 2', 'PACK 2', 4, 'available'),
(14, 'PACK 3', 'PACK 3', 4, 'available'),
(15, 'PACK 4', 'PACK 4', 4, 'available'),
(16, 'DELIVERY 1', 'DELIVERY 1', 4, 'available'),
(17, 'DELIVERY 2', 'DELIVERY 2', 4, 'available'),
(18, 'DELIVERY 3', 'DELIVERY 3', 4, 'available'),
(19, 'DELIVERY 4', 'DELIVERY 4', 4, 'available')
ON CONFLICT (id) DO UPDATE SET status = 'available';

-- Seed Default IAM Roles
INSERT INTO public.iam_roles (id, role_name, description) VALUES
(1, 'Admin', 'Full operational and financial management authority'),
(2, 'Manager', 'Store manager with discount approval authority'),
(3, 'Cashier', 'POS cashier for order booking, billing, and settlements'),
(4, 'Kitchen', 'KDS display monitor and order preparation'),
(5, 'Rider', 'Delivery dispatcher and rider tracker')
ON CONFLICT (id) DO NOTHING;

