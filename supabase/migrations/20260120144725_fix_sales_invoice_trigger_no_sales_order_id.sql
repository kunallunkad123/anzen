/*
  # Fix Sales Invoice Trigger - Remove sales_order_id Reference
  
  1. Issue
    - apply_advance_to_invoice() trigger references NEW.sales_order_id
    - But sales_invoices table does NOT have sales_order_id column
    - This causes error: "record 'new' has no field 'sales_order_id'"
  
  2. Solution
    - Drop the trigger temporarily since sales_invoices are not linked to sales_orders
    - Advances should be handled at sales_order level, not invoice level
    - This functionality belongs in a different flow
  
  3. Future Enhancement
    - If we want to link invoices to orders, add sales_order_id column first
    - Then re-enable this trigger
*/

-- Drop the problematic trigger
DROP TRIGGER IF EXISTS trg_apply_advance_to_invoice ON sales_invoices;

-- Drop the function since it's not being used
DROP FUNCTION IF EXISTS apply_advance_to_invoice();

-- Note: Advance payment allocation is handled through voucher_allocations
-- at the sales_order level, not at the invoice level
