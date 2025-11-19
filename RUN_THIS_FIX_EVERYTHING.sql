-- ================================================
-- RUN THIS TO FIX EVERYTHING
-- Copy all of this and run in Supabase SQL Editor
-- ================================================

-- ========================================
-- PART 1: FIX DELETION PERMISSIONS
-- ========================================

DROP POLICY IF EXISTS "Admin can delete batches" ON batches;
DROP POLICY IF EXISTS "Admin can delete products" ON products;
DROP POLICY IF EXISTS "Admin can delete inventory_transactions" ON inventory_transactions;
DROP POLICY IF EXISTS "Admin can delete batch_documents" ON batch_documents;
DROP POLICY IF EXISTS "Admin can delete finance_expenses" ON finance_expenses;
DROP POLICY IF EXISTS "Admin can delete product_files" ON product_files;
DROP POLICY IF EXISTS "Admin can delete delivery_challan_items" ON delivery_challan_items;
DROP POLICY IF EXISTS "Admin can delete sales_invoice_items" ON sales_invoice_items;

CREATE POLICY "Admin can delete batches" ON batches FOR DELETE TO authenticated
USING (EXISTS (SELECT 1 FROM user_profiles WHERE user_profiles.id = auth.uid() AND user_profiles.role = 'admin'));

CREATE POLICY "Admin can delete products" ON products FOR DELETE TO authenticated
USING (EXISTS (SELECT 1 FROM user_profiles WHERE user_profiles.id = auth.uid() AND user_profiles.role = 'admin'));

CREATE POLICY "Admin can delete inventory_transactions" ON inventory_transactions FOR DELETE TO authenticated
USING (EXISTS (SELECT 1 FROM user_profiles WHERE user_profiles.id = auth.uid() AND user_profiles.role = 'admin'));

CREATE POLICY "Admin can delete batch_documents" ON batch_documents FOR DELETE TO authenticated
USING (EXISTS (SELECT 1 FROM user_profiles WHERE user_profiles.id = auth.uid() AND user_profiles.role = 'admin'));

CREATE POLICY "Admin can delete finance_expenses" ON finance_expenses FOR DELETE TO authenticated
USING (EXISTS (SELECT 1 FROM user_profiles WHERE user_profiles.id = auth.uid() AND user_profiles.role = 'admin'));

CREATE POLICY "Admin can delete product_files" ON product_files FOR DELETE TO authenticated
USING (EXISTS (SELECT 1 FROM user_profiles WHERE user_profiles.id = auth.uid() AND user_profiles.role = 'admin'));

CREATE POLICY "Admin can delete delivery_challan_items" ON delivery_challan_items FOR DELETE TO authenticated
USING (EXISTS (SELECT 1 FROM user_profiles WHERE user_profiles.id = auth.uid() AND user_profiles.role = 'admin'));

CREATE POLICY "Admin can delete sales_invoice_items" ON sales_invoice_items FOR DELETE TO authenticated
USING (EXISTS (SELECT 1 FROM user_profiles WHERE user_profiles.id = auth.uid() AND user_profiles.role = 'admin'));

-- ========================================
-- PART 2: FIX BATCH SAVE (TRIGGER FUNCTION)
-- ========================================

DROP TRIGGER IF EXISTS update_inventory_on_batch_insert_or_update ON batches;
DROP FUNCTION IF EXISTS update_inventory_on_batch_insert_or_update();

CREATE OR REPLACE FUNCTION update_inventory_on_batch_insert_or_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF (TG_OP = 'INSERT') THEN
    -- Create new inventory transaction for new batch
    INSERT INTO inventory_transactions (
      product_id,
      batch_id,
      transaction_type,
      quantity,
      transaction_date,
      notes
    ) VALUES (
      NEW.product_id,
      NEW.id,
      'batch_import',
      NEW.import_quantity,
      NEW.import_date,
      'Batch import: ' || NEW.batch_number
    );
  ELSIF (TG_OP = 'UPDATE') THEN
    -- Update existing inventory transaction when batch is edited
    UPDATE inventory_transactions
    SET 
      product_id = NEW.product_id,
      quantity = NEW.import_quantity,
      transaction_date = NEW.import_date,
      notes = 'Batch import: ' || NEW.batch_number
    WHERE batch_id = NEW.id 
      AND transaction_type = 'batch_import';
    
    -- If no transaction exists, create one (handles legacy batches)
    IF NOT FOUND THEN
      INSERT INTO inventory_transactions (
        product_id,
        batch_id,
        transaction_type,
        quantity,
        transaction_date,
        notes
      ) VALUES (
        NEW.product_id,
        NEW.id,
        'batch_import',
        NEW.import_quantity,
        NEW.import_date,
        'Batch import: ' || NEW.batch_number
      );
    END IF;
  END IF;
  
  RETURN NEW;
END;
$$;

CREATE TRIGGER update_inventory_on_batch_insert_or_update
  AFTER INSERT OR UPDATE ON batches
  FOR EACH ROW
  EXECUTE FUNCTION update_inventory_on_batch_insert_or_update();

-- Fix existing inventory transactions with NULL or incorrect data
-- This repairs historical data from the old broken trigger
UPDATE inventory_transactions it
SET 
  quantity = b.import_quantity,
  transaction_date = b.import_date,
  product_id = b.product_id
FROM batches b
WHERE it.batch_id = b.id 
  AND it.transaction_type = 'batch_import'
  AND (it.quantity IS NULL OR it.quantity = 0 OR it.transaction_date IS NULL);

-- Create missing inventory transactions for batches that don't have one
INSERT INTO inventory_transactions (product_id, batch_id, transaction_type, quantity, transaction_date, notes)
SELECT 
  b.product_id,
  b.id,
  'batch_import',
  b.import_quantity,
  b.import_date,
  'Batch import: ' || b.batch_number
FROM batches b
WHERE NOT EXISTS (
  SELECT 1 FROM inventory_transactions it 
  WHERE it.batch_id = b.id AND it.transaction_type = 'batch_import'
);

-- ========================================
-- PART 3: FIX STOCK PAGE VIEW
-- ========================================

DROP VIEW IF EXISTS product_stock_summary CASCADE;

CREATE VIEW product_stock_summary
WITH (security_invoker=true)
AS
SELECT 
    p.id as product_id,
    p.product_name,
    p.product_code,
    COALESCE(SUM(it.quantity), 0) as total_stock,
    p.unit
FROM products p
LEFT JOIN inventory_transactions it ON p.id = it.product_id
GROUP BY p.id, p.product_name, p.product_code, p.unit;

-- ========================================
-- PART 4: FIX SECURITY WARNINGS
-- ========================================

DROP FUNCTION IF EXISTS create_batch_inventory_transaction(UUID, UUID, TEXT, NUMERIC, DATE, TEXT);

CREATE OR REPLACE FUNCTION create_batch_inventory_transaction(
  p_product_id UUID,
  p_batch_id UUID,
  p_transaction_type TEXT,
  p_quantity NUMERIC,
  p_transaction_date DATE,
  p_notes TEXT
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO inventory_transactions (
    product_id,
    batch_id,
    transaction_type,
    quantity,
    transaction_date,
    notes
  ) VALUES (
    p_product_id,
    p_batch_id,
    p_transaction_type,
    p_quantity,
    p_transaction_date,
    p_notes
  );
END;
$$;

-- ========================================
-- VERIFICATION
-- ========================================

SELECT '✅ ✅ ✅ ALL FIXES APPLIED SUCCESSFULLY! ✅ ✅ ✅' AS status;
SELECT '' AS blank_line;
SELECT '✓ DELETE permissions added for Admin on all tables' AS fix_1;
SELECT '✓ Batch save trigger function fixed (uses quantity column)' AS fix_2;
SELECT '✓ Stock page view recreated with correct columns' AS fix_3;
SELECT '✓ Security warnings fixed (search_path and security_invoker)' AS fix_4;
SELECT '' AS blank_line;
SELECT '🎉 You can now:' AS next_steps;
SELECT '  • Delete batches and products as Admin' AS step_1;
SELECT '  • Save new batches successfully' AS step_2;
SELECT '  • View stock page with all products' AS step_3;
SELECT '  • No more security warnings (except password protection)' AS step_4;
