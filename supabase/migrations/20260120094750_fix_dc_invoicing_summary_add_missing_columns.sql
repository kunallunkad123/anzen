/*
  # Fix DC Invoicing Summary View - Add Missing Columns
  
  1. Problem
    - View is missing customer_id, challan_date, and quantity columns
    - Frontend needs these to filter DCs by customer and show DC details
    - Current view only shows challan_id and challan_number
  
  2. Solution
    - Recreate view with all required columns:
      - customer_id (for filtering)
      - challan_date (for ordering)
      - total_quantity (sum of all item quantities)
      - total_remaining_quantity (sum of uninvoiced quantities)
  
  3. Changes
    - Drop and recreate dc_invoicing_summary view
    - Add customer_id, challan_date, quantity aggregations
*/

DROP VIEW IF EXISTS dc_invoicing_summary CASCADE;

CREATE VIEW dc_invoicing_summary AS
SELECT 
  dc.id AS challan_id,
  dc.challan_number,
  dc.customer_id,
  dc.challan_date,
  dc.approval_status,
  
  -- Count items
  COUNT(DISTINCT dci.id) AS total_items,
  COUNT(DISTINCT CASE WHEN sii.id IS NULL THEN dci.id ELSE NULL END) AS not_invoiced_items,
  COUNT(DISTINCT CASE WHEN sii.id IS NOT NULL THEN dci.id ELSE NULL END) AS invoiced_items,
  
  -- Quantity aggregations
  COALESCE(SUM(dci.quantity), 0) AS total_quantity,
  COALESCE(SUM(
    CASE 
      WHEN sii.id IS NULL THEN dci.quantity
      ELSE 0
    END
  ), 0) AS total_remaining_quantity,
  
  -- Status
  CASE
    WHEN COUNT(DISTINCT sii.id) = 0 THEN 'not_invoiced'
    WHEN COUNT(DISTINCT sii.id) < COUNT(DISTINCT dci.id) THEN 'partially_invoiced'
    ELSE 'fully_invoiced'
  END AS dc_status,
  
  -- Linked invoices
  COALESCE(
    ARRAY_AGG(DISTINCT si.invoice_number) FILTER (WHERE si.invoice_number IS NOT NULL),
    ARRAY[]::TEXT[]
  ) AS linked_invoices

FROM delivery_challans dc
LEFT JOIN delivery_challan_items dci ON dc.id = dci.challan_id
LEFT JOIN sales_invoice_items sii ON sii.delivery_challan_item_id = dci.id
LEFT JOIN sales_invoices si ON sii.invoice_id = si.id
WHERE dc.approval_status = 'approved'
GROUP BY dc.id, dc.challan_number, dc.customer_id, dc.challan_date, dc.approval_status;

-- Add comment
COMMENT ON VIEW dc_invoicing_summary IS 'Summary of delivery challans with invoicing status and remaining quantities for approved DCs only';
