/*
  # Fix Receipt Voucher Allocation and Invoice Payment Tracking
  
  1. Issues
    - get_invoice_paid_amount() references wrong table (invoice_payment_allocations)
    - sales_invoices missing paid_amount and balance_amount columns
    - Trigger exists but can't update missing columns
  
  2. Fix
    - Add paid_amount and balance_amount to sales_invoices
    - Fix get_invoice_paid_amount() to use voucher_allocations
    - Fix update_invoice_payment_status_from_allocation() to update both columns
  
  3. Columns
    - paid_amount: Total amount paid against this invoice
    - balance_amount: Remaining amount due
*/

-- Add missing columns to sales_invoices
ALTER TABLE sales_invoices
ADD COLUMN IF NOT EXISTS paid_amount NUMERIC(18,2) DEFAULT 0,
ADD COLUMN IF NOT EXISTS balance_amount NUMERIC(18,2) DEFAULT 0;

-- Fix the get_invoice_paid_amount function to use correct table
CREATE OR REPLACE FUNCTION get_invoice_paid_amount(p_invoice_id UUID)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_paid_amount NUMERIC;
BEGIN
  -- Calculate from voucher_allocations where type is receipt and linked to sales_invoice
  SELECT COALESCE(SUM(allocated_amount), 0)
  INTO v_paid_amount
  FROM voucher_allocations
  WHERE sales_invoice_id = p_invoice_id
    AND voucher_type = 'receipt';
  
  RETURN v_paid_amount;
END;
$$;

-- Fix the trigger function to update paid_amount and balance_amount
CREATE OR REPLACE FUNCTION update_invoice_payment_status_from_allocation()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_total_paid NUMERIC;
  v_invoice_total NUMERIC;
  v_invoice_id UUID;
BEGIN
  -- Get the invoice ID
  IF TG_OP = 'DELETE' THEN
    v_invoice_id := OLD.sales_invoice_id;
  ELSE
    v_invoice_id := NEW.sales_invoice_id;
  END IF;
  
  -- Only process if there's an invoice ID and it's a receipt voucher
  IF v_invoice_id IS NULL THEN
    IF TG_OP = 'DELETE' THEN
      RETURN OLD;
    ELSE
      RETURN NEW;
    END IF;
  END IF;
  
  -- Only process receipt vouchers
  IF TG_OP = 'DELETE' AND OLD.voucher_type != 'receipt' THEN
    RETURN OLD;
  END IF;
  
  IF TG_OP != 'DELETE' AND NEW.voucher_type != 'receipt' THEN
    RETURN NEW;
  END IF;
  
  -- Calculate total paid for the invoice
  v_total_paid := get_invoice_paid_amount(v_invoice_id);
  
  -- Get invoice total
  SELECT total_amount INTO v_invoice_total
  FROM sales_invoices
  WHERE id = v_invoice_id;
  
  -- Update paid_amount, balance_amount, and payment_status
  UPDATE sales_invoices
  SET 
    paid_amount = v_total_paid,
    balance_amount = v_invoice_total - v_total_paid,
    payment_status = CASE
      WHEN v_total_paid = 0 THEN 'pending'
      WHEN v_total_paid >= v_invoice_total THEN 'paid'
      ELSE 'partial'
    END,
    updated_at = NOW()
  WHERE id = v_invoice_id;
  
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  ELSE
    RETURN NEW;
  END IF;
END;
$$;

-- Drop existing trigger if exists
DROP TRIGGER IF EXISTS trg_update_invoice_payment_status ON voucher_allocations;

-- Recreate trigger (simplified - no WHEN clause)
CREATE TRIGGER trg_update_invoice_payment_status
AFTER INSERT OR UPDATE OR DELETE ON voucher_allocations
FOR EACH ROW
EXECUTE FUNCTION update_invoice_payment_status_from_allocation();

-- Backfill existing invoices with current paid amounts
UPDATE sales_invoices si
SET 
  paid_amount = COALESCE((
    SELECT SUM(allocated_amount)
    FROM voucher_allocations
    WHERE sales_invoice_id = si.id
      AND voucher_type = 'receipt'
  ), 0),
  balance_amount = si.total_amount - COALESCE((
    SELECT SUM(allocated_amount)
    FROM voucher_allocations
    WHERE sales_invoice_id = si.id
      AND voucher_type = 'receipt'
  ), 0),
  payment_status = CASE
    WHEN COALESCE((
      SELECT SUM(allocated_amount)
      FROM voucher_allocations
      WHERE sales_invoice_id = si.id
        AND voucher_type = 'receipt'
    ), 0) = 0 THEN 'pending'
    WHEN COALESCE((
      SELECT SUM(allocated_amount)
      FROM voucher_allocations
      WHERE sales_invoice_id = si.id
        AND voucher_type = 'receipt'
    ), 0) >= si.total_amount THEN 'paid'
    ELSE 'partial'
  END
WHERE id IN (
  SELECT DISTINCT sales_invoice_id
  FROM voucher_allocations
  WHERE sales_invoice_id IS NOT NULL
);
