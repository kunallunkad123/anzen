/*
  # Fix DISTINCT ON Column Reference Error
  
  1. Issue
    - DISTINCT ON references columns that don't exist in the SELECT context
    - Need to use numbered positions instead of column names
  
  2. Fix
    - Use DISTINCT ON with column positions (2, 3, 7) instead of names
    - Or use a CTE to properly reference columns
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

  -- Step 3: Insert new items with deduplication using CTE
  INSERT INTO sales_invoice_items (
    invoice_id,
    product_id,
    batch_id,
    quantity,
    unit_price,
    tax_rate,
    delivery_challan_item_id
  )
  WITH parsed_items AS (
    SELECT
      p_invoice_id as invoice_id,
      (item->>'product_id')::uuid as product_id,
      (item->>'batch_id')::uuid as batch_id,
      (item->>'quantity')::numeric as quantity,
      (item->>'unit_price')::numeric as unit_price,
      (item->>'tax_rate')::numeric as tax_rate,
      NULLIF(item->>'delivery_challan_item_id', '')::uuid as delivery_challan_item_id
    FROM unnest(p_new_items) AS item
    WHERE (item->>'product_id') IS NOT NULL 
      AND (item->>'product_id')::text != ''
  )
  SELECT DISTINCT ON (product_id, batch_id, delivery_challan_item_id)
    invoice_id,
    product_id,
    batch_id,
    quantity,
    unit_price,
    tax_rate,
    delivery_challan_item_id
  FROM parsed_items;

  RETURN v_result;
END;
$$;
