/*
  # Create Journal Flat View (Tally-Style)
  
  1. Purpose
    - Creates a flat, scan-friendly journal view matching Tally accounting software
    - Each ledger line appears as one row (no grouping)
    - Voucher numbers repeat for multi-line entries
    - Optimized for CA review and audit trails
  
  2. View Structure
    - Combines journal_entries, journal_entry_lines, and chart_of_accounts
    - Displays: Date | Voucher No | Voucher Type | Ledger | Debit | Credit | Narration
    - One row per journal line (not per journal entry)
  
  3. Usage
    - Frontend reads from this view (READ ONLY)
    - Editing happens through voucher view
    - Supports all existing filters and search
*/

-- Create flat journal view for Tally-style display
CREATE OR REPLACE VIEW journal_flat_view AS
SELECT
  je.id AS journal_entry_id,
  jel.id AS line_id,
  je.entry_date AS date,
  je.entry_number AS voucher_no,
  CASE 
    WHEN je.source_module = 'sales_invoice' THEN 'Sales Invoice'
    WHEN je.source_module = 'purchase_invoice' THEN 'Purchase Invoice'
    WHEN je.source_module = 'receipt' THEN 'Receipt Voucher'
    WHEN je.source_module = 'payment' THEN 'Payment Voucher'
    WHEN je.source_module = 'petty_cash' THEN 'Petty Cash'
    WHEN je.source_module = 'manual' THEN 'Journal'
    ELSE 'Journal'
  END AS voucher_type,
  coa.code AS account_code,
  coa.name AS ledger,
  COALESCE(jel.debit, 0) AS debit,
  COALESCE(jel.credit, 0) AS credit,
  COALESCE(jel.description, je.description, '') AS narration,
  je.reference_number,
  je.source_module,
  je.is_posted,
  je.is_reversed,
  jel.line_number,
  c.company_name AS customer_name,
  s.company_name AS supplier_name,
  je.created_at,
  je.posted_at
FROM journal_entries je
INNER JOIN journal_entry_lines jel ON je.id = jel.journal_entry_id
INNER JOIN chart_of_accounts coa ON jel.account_id = coa.id
LEFT JOIN customers c ON jel.customer_id = c.id
LEFT JOIN suppliers s ON jel.supplier_id = s.id
ORDER BY je.entry_date DESC, je.entry_number DESC, jel.line_number ASC;

-- Add comment for documentation
COMMENT ON VIEW journal_flat_view IS 'Tally-style flat journal view - one row per ledger line. READ ONLY. For editing, use journal_entries and journal_entry_lines tables directly.';

-- Create index on underlying tables for performance (if not exists)
CREATE INDEX IF NOT EXISTS idx_journal_entries_entry_date 
  ON journal_entries(entry_date DESC);

CREATE INDEX IF NOT EXISTS idx_journal_entries_entry_number 
  ON journal_entries(entry_number);

CREATE INDEX IF NOT EXISTS idx_journal_entry_lines_journal_entry_id 
  ON journal_entry_lines(journal_entry_id);

CREATE INDEX IF NOT EXISTS idx_journal_entry_lines_account_id 
  ON journal_entry_lines(account_id);
