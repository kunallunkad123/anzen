-- ================================================================
-- COMPLETE FIX: Sales, Inventory, and Stock Synchronization
-- ================================================================
-- This creates all missing functions and triggers to keep everything in sync

-- ============================================
-- 1. Create update_batch_stock function (for Delivery Challan)
-- ============================================
CREATE OR REPLACE FUNCTION update_batch_stock(
  p_batch_id uuid,
  p_adjustment numeric
)
RETURNS void AS $$
BEGIN
  UPDATE batches
  SET current_stock = current_stock + p_adjustment
  WHERE id = p_batch_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION update_batch_stock IS 'Updates batch stock by adding an adjustment (positive or negative)';

-- ============================================
-- 2. Create function to sync batch stock when sales change
-- ============================================
CREATE OR REPLACE FUNCTION sync_batch_stock_on_sale()
RETURNS TRIGGER AS $$
BEGIN
  IF (TG_OP = 'INSERT') THEN
    -- Decrease batch stock when sale is created
    UPDATE batches
    SET current_stock = current_stock - NEW.quantity
    WHERE id = NEW.batch_id;
    
    -- Create inventory transaction for the sale
    INSERT INTO inventory_transactions (
      transaction_type,
      product_id,
      batch_id,
      quantity,
      reference_number,
      notes,
      transaction_date,
      created_by
    )
    SELECT
      'sale',
      NEW.product_id,
      NEW.batch_id,
      -NEW.quantity,  -- Negative because it's a sale (stock decrease)
      si.invoice_number,
      'Sale: Invoice ' || si.invoice_number,
      si.invoice_date,
      si.created_by
    FROM sales_invoices si
    WHERE si.id = NEW.invoice_id;
    
    RETURN NEW;
    
  ELSIF (TG_OP = 'UPDATE') THEN
    -- Adjust batch stock when quantity changes
    IF OLD.quantity IS DISTINCT FROM NEW.quantity THEN
      -- Restore old quantity and deduct new quantity
      UPDATE batches
      SET current_stock = current_stock + OLD.quantity - NEW.quantity
      WHERE id = NEW.batch_id;
      
      -- Update the inventory transaction
      UPDATE inventory_transactions
      SET quantity = -NEW.quantity
      WHERE batch_id = NEW.batch_id
        AND transaction_type = 'sale'
        AND reference_number IN (
          SELECT invoice_number FROM sales_invoices WHERE id = NEW.invoice_id
        );
    END IF;
    
    RETURN NEW;
    
  ELSIF (TG_OP = 'DELETE') THEN
    -- Restore stock when sale is deleted
    UPDATE batches
    SET current_stock = current_stock + OLD.quantity
    WHERE id = OLD.batch_id;
    
    -- Delete the inventory transaction
    DELETE FROM inventory_transactions
    WHERE batch_id = OLD.batch_id
      AND transaction_type = 'sale'
      AND reference_number IN (
        SELECT invoice_number FROM sales_invoices WHERE id = OLD.invoice_id
      );
    
    RETURN OLD;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================
-- 3. Create trigger on sales_invoice_items
-- ============================================
DROP TRIGGER IF EXISTS trigger_sync_batch_stock_on_sale ON sales_invoice_items;

CREATE TRIGGER trigger_sync_batch_stock_on_sale
  AFTER INSERT OR UPDATE OR DELETE ON sales_invoice_items
  FOR EACH ROW
  EXECUTE FUNCTION sync_batch_stock_on_sale();

-- ============================================
-- 4. Backfill: Create inventory transactions for existing sales
-- ============================================
INSERT INTO inventory_transactions (
  transaction_type,
  product_id,
  batch_id,
  quantity,
  reference_number,
  notes,
  transaction_date,
  created_by
)
SELECT DISTINCT
  'sale',
  sii.product_id,
  sii.batch_id,
  -sii.quantity,  -- Negative for sales
  si.invoice_number,
  'Sale: Invoice ' || si.invoice_number,
  si.invoice_date,
  si.created_by
FROM sales_invoice_items sii
JOIN sales_invoices si ON si.id = sii.invoice_id
WHERE NOT EXISTS (
  SELECT 1 FROM inventory_transactions it
  WHERE it.batch_id = sii.batch_id
    AND it.transaction_type = 'sale'
    AND it.reference_number = si.invoice_number
)
AND sii.batch_id IS NOT NULL;

-- ============================================
-- 5. Fix all batch stock based on actual sales
-- ============================================
DO $$
DECLARE
  batch_record RECORD;
  actual_sold_qty numeric;
BEGIN
  FOR batch_record IN 
    SELECT id, batch_number, import_quantity, current_stock 
    FROM batches 
    WHERE is_active = true
  LOOP
    -- Calculate actual sold quantity from sales_invoice_items
    SELECT COALESCE(SUM(quantity), 0) INTO actual_sold_qty
    FROM sales_invoice_items
    WHERE batch_id = batch_record.id;

    -- Update current_stock to correct value
    UPDATE batches
    SET current_stock = batch_record.import_quantity - actual_sold_qty
    WHERE id = batch_record.id;

    RAISE NOTICE 'Synced batch %: import=%, sold=%, current_stock=%',
      batch_record.batch_number,
      batch_record.import_quantity,
      actual_sold_qty,
      (batch_record.import_quantity - actual_sold_qty);
  END LOOP;
END $$;

-- Success!
SELECT '✅ SALES AND STOCK SYNC COMPLETE!' AS status;
SELECT 'Batches synced, inventory transactions created, triggers active' AS message;
