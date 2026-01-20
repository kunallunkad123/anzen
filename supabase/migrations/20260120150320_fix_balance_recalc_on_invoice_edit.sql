/*
  # Fix Balance Recalculation on Invoice Edit
  
  1. Issue
    - When invoice total_amount is updated, balance_amount should also update
    - Currently only initializes on INSERT
  
  2. Fix
    - Update trigger to also recalculate balance on UPDATE when total_amount changes
*/

CREATE OR REPLACE FUNCTION initialize_invoice_amounts()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- On INSERT: Initialize paid_amount and balance_amount
  IF TG_OP = 'INSERT' THEN
    IF NEW.paid_amount IS NULL THEN
      NEW.paid_amount := 0;
    END IF;
    
    IF NEW.balance_amount IS NULL OR NEW.balance_amount = 0 THEN
      NEW.balance_amount := NEW.total_amount;
    END IF;
  END IF;
  
  -- On UPDATE: Recalculate balance_amount if total_amount changed
  IF TG_OP = 'UPDATE' AND OLD.total_amount != NEW.total_amount THEN
    -- Recalculate balance: new total - current paid
    NEW.balance_amount := NEW.total_amount - COALESCE(NEW.paid_amount, 0);
    
    -- Recalculate payment status
    IF NEW.paid_amount = 0 THEN
      NEW.payment_status := 'pending';
    ELSIF NEW.paid_amount >= NEW.total_amount THEN
      NEW.payment_status := 'paid';
    ELSE
      NEW.payment_status := 'partial';
    END IF;
  END IF;
  
  RETURN NEW;
END;
$$;

-- Drop and recreate trigger to handle both INSERT and UPDATE
DROP TRIGGER IF EXISTS trg_initialize_invoice_amounts ON sales_invoices;

CREATE TRIGGER trg_initialize_invoice_amounts
BEFORE INSERT OR UPDATE ON sales_invoices
FOR EACH ROW
EXECUTE FUNCTION initialize_invoice_amounts();
