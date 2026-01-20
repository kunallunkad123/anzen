/*
  # Fix Sales Invoice Balance Initialization
  
  1. Issue
    - paid_amount and balance_amount are added but not initialized properly
    - balance_amount should equal total_amount on insert
    - Current trigger doesn't set these values
  
  2. Fix
    - Add BEFORE INSERT trigger to set balance_amount = total_amount
    - Set paid_amount = 0 by default
    - This ensures new invoices have correct initial values
*/

-- Create function to initialize invoice amounts
CREATE OR REPLACE FUNCTION initialize_invoice_amounts()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Initialize paid_amount to 0 if not set
  IF NEW.paid_amount IS NULL THEN
    NEW.paid_amount := 0;
  END IF;
  
  -- Initialize balance_amount to total_amount if not set
  IF NEW.balance_amount IS NULL OR NEW.balance_amount = 0 THEN
    NEW.balance_amount := NEW.total_amount;
  END IF;
  
  RETURN NEW;
END;
$$;

-- Create trigger to run before insert
DROP TRIGGER IF EXISTS trg_initialize_invoice_amounts ON sales_invoices;

CREATE TRIGGER trg_initialize_invoice_amounts
BEFORE INSERT ON sales_invoices
FOR EACH ROW
EXECUTE FUNCTION initialize_invoice_amounts();

-- Backfill existing invoices with balance_amount = total_amount - paid_amount
UPDATE sales_invoices
SET balance_amount = total_amount - COALESCE(paid_amount, 0)
WHERE balance_amount = 0 OR balance_amount IS NULL;
