/*
  # Fix Duplicate Items on Invoice Edit
  
  1. Issue
    - When editing invoices, duplicate line items are being created
    - Same product+batch being inserted twice
  
  2. Root Cause
    - Frontend may be sending duplicate items in array
    - OR function being called twice accidentally
  
  3. Fix
    - Deduplicate items based on product_id, batch_id, and delivery_challan_item_id
    - Use DISTINCT ON to ensure each unique combination is inserted only once
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

  -- Step 3: Insert new items with deduplication
  -- Use DISTINCT ON to prevent duplicate line items
  INSERT INTO sales_invoice_items (
    invoice_id,
    product_id,
    batch_id,
    quantity,
    unit_price,
    tax_rate,
    delivery_challan_item_id
  )
  SELECT DISTINCT ON (product_id, batch_id, delivery_challan_item_id)
    p_invoice_id,
    (item->>'product_id')::uuid,
    (item->>'batch_id')::uuid,
    (item->>'quantity')::numeric,
    (item->>'unit_price')::numeric,
    (item->>'tax_rate')::numeric,
    NULLIF(item->>'delivery_challan_item_id', '')::uuid
  FROM unnest(p_new_items) AS item
  WHERE (item->>'product_id') IS NOT NULL 
    AND (item->>'product_id')::text != '';

  RETURN v_result;
END;
$$;
