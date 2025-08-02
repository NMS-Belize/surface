INSERT INTO wx_crop(created_at, updated_at, name, cycle, l_ini, l_dev, l_mid, l_late, kc_ini, kc_mid, kc_end, max_ht)

VALUES 
(NOW(), NOW(), 'Cassava (Year 1)', 210, 20, 40, 90, 60, 0.3, 0.8, 0.3,1),
(NOW(), NOW(), 'Cassava (Year 2)', 360, 150, 40, 110, 60, 0.3, 1.1, 0.5, 1.5),
(NOW(), NOW(), 'Sweet Potato', 125, 15, 30, 50, 30, 0.4, 1.15, 0.65,0.4),
(NOW(), NOW(), 'Sugarcane (Plant)', 405, 35, 60, 190, 120, 0.4, 1.25, 0.75, 3),
(NOW(), NOW(), 'Sugarcane (Ratoon)', 280, 25, 70, 135, 50, 0.4, 1.25, 0.75, 3),
(NOW(), NOW(), 'Grapes (Table or Raisin)', 240, 20, 40, 120, 60, 0.3, 0.85, 0.45, 2),
(NOW(), NOW(), 'Grapes (Wine)', 240, 20, 40, 120, 60, 0.3, 0.7, 0.45, 2),
(NOW(), NOW(), 'Banana (Dwarf Cavendish)', 360, 30, 60, 180, 90, 0.5, 1.2, 0.7, 2.5),
(NOW(), NOW(), 'Maize (Grain)', 115, 15, 30, 40, 30, 0.3, 1.15, 0.5, 2),
(NOW(), NOW(), 'Rice (Paddy, Lowland)', 140, 20, 30, 60, 30, 1, 1.1, 0.65, 1.2),
(NOW(), NOW(), 'Citrus (Oranges)', 420, 60, 120, 150, 90, 0.7, 0.8, 0.6, 4),
(NOW(), NOW(), 'Tomato (Fresh Market)', 135, 25, 30, 50, 30, 0.6, 1.15, 0.8, 1.5),
(NOW(), NOW(), 'Bell Pepper', 135, 25, 30, 50, 30, 0.4, 1.05, 0.75, 0.8),
(NOW(), NOW(), 'Pineapple', 480, 60, 120, 180, 120, 0.5, 0.9, 0.7, 1.2);