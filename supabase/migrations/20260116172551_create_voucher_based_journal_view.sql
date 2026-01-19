/*
  # Create Voucher-Based Journal View
  
  1. Purpose
    - Replace line-based view with voucher-based view
    - Show one row per journal entry
    - Display main debit and credit accounts in same row
    - Proper narrations from source descriptions
  
  2. Structure
    - Date | Journal No | Type | Debit Account | Credit Account | Amount | Narration
    - For multi-line entries, show primary Dr/Cr accounts
    - Click to expand shows all lines
  
  3. Usage
    - Frontend displays this view by default
    - Clean, accountant-friendly format
    - Easy to scan and analyze
*/

-- Drop old flat view
DROP VIEW IF EXISTS journal_flat_view CASCADE;

-- Create voucher-based journal view
CREATE OR REPLACE VIEW journal_voucher_view AS
SELECT
  je.id AS journal_entry_id,
  je.entry_date AS date,
  je.entry_number AS voucher_no,
  CASE 
    WHEN je.source_module = 'sales_invoice' THEN 'Sales Invoice'
    WHEN je.source_module = 'sales_invoice_cogs' THEN 'COGS Entry'
    WHEN je.source_module = 'purchase_invoice' THEN 'Purchase Invoice'
    WHEN je.source_module = 'receipt' THEN 'Receipt Voucher'
    WHEN je.source_module = 'payment' THEN 'Payment Voucher'
    WHEN je.source_module = 'petty_cash' THEN 'Petty Cash'
    WHEN je.source_module = 'fund_transfer' THEN 'Fund Transfer'
    WHEN je.source_module = 'expenses' THEN 'Expense'
    WHEN je.source_module = 'manual' THEN 'Journal'
    ELSE 'Journal'
  END AS voucher_type,
  -- Get primary debit account (first debit line)
  (
    SELECT coa.code || ' - ' || coa.name
    FROM journal_entry_lines jel
    JOIN chart_of_accounts coa ON jel.account_id = coa.id
    WHERE jel.journal_entry_id = je.id 
      AND jel.debit > 0
    ORDER BY jel.line_number
    LIMIT 1
  ) AS debit_account,
  -- Get primary credit account (first credit line)
  (
    SELECT coa.code || ' - ' || coa.name
    FROM journal_entry_lines jel
    JOIN chart_of_accounts coa ON jel.account_id = coa.id
    WHERE jel.journal_entry_id = je.id 
      AND jel.credit > 0
    ORDER BY jel.line_number
    LIMIT 1
  ) AS credit_account,
  je.total_debit AS amount,
  -- Get primary narration (from first debit line or journal description)
  COALESCE(
    (
      SELECT jel.description
      FROM journal_entry_lines jel
      WHERE jel.journal_entry_id = je.id 
        AND jel.debit > 0
        AND jel.description IS NOT NULL
        AND jel.description != ''
      ORDER BY jel.line_number
      LIMIT 1
    ),
    je.description
  ) AS narration,
  je.reference_number,
  je.source_module,
  je.is_posted,
  je.is_reversed,
  je.created_at,
  je.posted_at,
  -- Count of lines for expandable detail
  (
    SELECT COUNT(*)
    FROM journal_entry_lines jel
    WHERE jel.journal_entry_id = je.id
  ) AS line_count,
  -- Check if multi-line
  (
    SELECT COUNT(*) > 2
    FROM journal_entry_lines jel
    WHERE jel.journal_entry_id = je.id
  ) AS is_multi_line
FROM journal_entries je
WHERE je.is_posted = true
ORDER BY je.entry_date DESC, je.entry_number DESC;

-- Create index for performance
CREATE INDEX IF NOT EXISTS idx_journal_entries_date_number 
  ON journal_entries(entry_date DESC, entry_number DESC);

COMMENT ON VIEW journal_voucher_view IS 'Voucher-based journal view - one row per journal entry with primary Dr/Cr accounts visible';
