/*
  # Create DC Invoicing Summary View
  
  1. Purpose
    - Track which DC items have been invoiced
    - Show invoicing status: not_invoiced, partially_invoiced, fully_invoiced
    - Count items by status
    - List linked invoice numbers
  
  2. Logic
    - Join delivery_challan_items with sales_invoice_items
    - Count total items vs invoiced items
    - Calculate status based on item counts
    - Aggregate linked invoice numbers
*/

CREATE OR REPLACE VIEW dc_invoicing_summary AS
SELECT 
  dc.id as challan_id,
  dc.challan_number,
  COUNT(DISTINCT dci.id) as total_items,
  COUNT(DISTINCT CASE WHEN sii.id IS NULL THEN dci.id END) as not_invoiced_items,
  COUNT(DISTINCT CASE WHEN sii.id IS NOT NULL THEN dci.id END) as invoiced_items,
  0 as partially_invoiced_items,
  COUNT(DISTINCT CASE WHEN sii.id IS NOT NULL THEN dci.id END) as fully_invoiced_items,
  CASE 
    WHEN COUNT(DISTINCT sii.id) = 0 THEN 'not_invoiced'
    WHEN COUNT(DISTINCT sii.id) < COUNT(DISTINCT dci.id) THEN 'partially_invoiced'
    ELSE 'fully_invoiced'
  END as dc_status,
  COALESCE(
    array_agg(DISTINCT si.invoice_number) FILTER (WHERE si.invoice_number IS NOT NULL),
    ARRAY[]::text[]
  ) as linked_invoices
FROM delivery_challans dc
LEFT JOIN delivery_challan_items dci ON dc.id = dci.challan_id
LEFT JOIN sales_invoice_items sii ON sii.delivery_challan_item_id = dci.id
LEFT JOIN sales_invoices si ON sii.invoice_id = si.id
GROUP BY dc.id, dc.challan_number;

-- Grant access
GRANT SELECT ON dc_invoicing_summary TO authenticated;
