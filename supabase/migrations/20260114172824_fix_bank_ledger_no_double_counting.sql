/*
  # Fix Bank Ledger - Remove Double Counting

  1. Problem
    - Function was counting bank_statement_lines PLUS finance_expenses
    - But many expenses are already matched to bank statements (matched_expense_id)
    - This caused double counting and negative balances
    - Example: 137 out of 245 bank lines are matched to expenses

  2. Solution
    - Bank ledger should ONLY use bank_statement_lines
    - Bank statements are the source of truth for what's in the bank
    - All other transactions (receipts, payments, expenses) are already 
      reflected in bank statements when they clear

  3. Logic
    - Opening balance calculation = stored opening + bank statement net change
    - No need to add receipts/payments/expenses separately
*/

-- Drop the incorrect function
DROP FUNCTION IF EXISTS calculate_balance_between_dates(UUID, DATE, DATE);

-- Create correct function using ONLY bank statements
CREATE OR REPLACE FUNCTION calculate_balance_between_dates(
  p_bank_account_id UUID,
  p_start_date DATE,
  p_end_date DATE
)
RETURNS TABLE (net_change NUMERIC)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    COALESCE(SUM(credit_amount), 0) - COALESCE(SUM(debit_amount), 0) AS net_change
  FROM bank_statement_lines
  WHERE bank_account_id = p_bank_account_id
    AND transaction_date >= p_start_date
    AND transaction_date < p_end_date;
END;
$$;

-- Grant execute permission
GRANT EXECUTE ON FUNCTION calculate_balance_between_dates(UUID, DATE, DATE) TO authenticated;
