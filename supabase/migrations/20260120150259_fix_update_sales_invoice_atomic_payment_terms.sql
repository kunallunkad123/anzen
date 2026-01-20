/*
  # Fix update_sales_invoice_atomic - Payment Terms Column Name
  
  1. Issue
    - Function tries to update `payment_terms` column
    - But table has `payment_terms_days` column
    - Causes error: column "payment_terms" does not exist
  
  2. Fix
    - Change payment_terms to payment_terms_days in UPDATE statement
*/

CREATE OR REPLACE FUNCTION update_sales_invoice_atomic(
  p_invoice_id UUID,
  p_invoice_updates JSONB,
  p_new_items JSONB[]
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_result UUID;
BEGIN
  -- Step 1: Delete old items (triggers will restore stock automatically)
  DELETE FROM sales_invoice_items 
  WHERE invoice_id = p_invoice_id;

  -- Step 2: Update invoice header
  UPDATE sales_invoices
  SET
    invoice_date = COALESCE((p_invoice_updates->>'invoice_date')::date, invoice_date),
    due_date = COALESCE((p_invoice_updates->>'due_date')::date, due_date),
    customer_id = COALESCE((p_invoice_updates->>'customer_id')::uuid, customer_id),
    subtotal = COALESCE((p_invoice_updates->>'subtotal')::numeric, subtotal),
    tax_amount = COALESCE((p_invoice_updates->>'tax_amount')::numeric, tax_amount),
    total_amount = COALESCE((p_invoice_updates->>'total_amount')::numeric, total_amount),
    notes = COALESCE(p_invoice_updates->>'notes', notes),
    payment_terms_days = COALESCE((p_invoice_updates->>'payment_terms')::integer, payment_terms_days),
    updated_at = NOW()
  WHERE id = p_invoice_id
  RETURNING id INTO v_result;

  -- Step 3: Insert new items (triggers will deduct stock automatically)
  INSERT INTO sales_invoice_items (
    invoice_id,
    product_id,
    batch_id,
    quantity,
    unit_price,
    tax_rate,
    total_amount,
    delivery_challan_item_id,
    max_quantity
  )
  SELECT
    p_invoice_id,
    (item->>'product_id')::uuid,
    (item->>'batch_id')::uuid,
    (item->>'quantity')::numeric,
    (item->>'unit_price')::numeric,
    (item->>'tax_rate')::numeric,
    (item->>'total_amount')::numeric,
    NULLIF(item->>'delivery_challan_item_id', '')::uuid,
    (item->>'max_quantity')::numeric
  FROM unnest(p_new_items) AS item;

  RETURN v_result;
END;
$$;
