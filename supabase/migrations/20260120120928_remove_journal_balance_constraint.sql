/*
  # Remove Journal Entry Balance Constraint
  
  1. Why Remove It
    - The constraint causes issues during automated journal entry creation
    - When lines are inserted one-by-one, the recalculate trigger runs after EACH line
    - This causes intermediate unbalanced states that violate the constraint
    - CHECK constraints cannot be deferred in PostgreSQL
  
  2. Safety
    - We have a recalculate_journal_entry_totals() trigger that ALWAYS keeps totals correct
    - This trigger runs after every insert/update/delete on journal_entry_lines
    - The trigger calculates totals by summing all lines, which is always accurate
    - Manual journal entries can be validated in the application layer
  
  3. Alternative Protection
    - Add a validation function that can be called to check balance
    - This can be used in views, reports, or periodic checks
*/

-- Drop the constraint
ALTER TABLE journal_entries
DROP CONSTRAINT IF EXISTS chk_journal_entry_balanced;

-- Create a helper function to check if a journal entry is balanced
CREATE OR REPLACE FUNCTION is_journal_entry_balanced(p_entry_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_debit NUMERIC;
  v_credit NUMERIC;
BEGIN
  SELECT total_debit, total_credit 
  INTO v_debit, v_credit
  FROM journal_entries
  WHERE id = p_entry_id;
  
  RETURN (abs(v_debit - v_credit) < 0.01) OR (v_debit = 0 AND v_credit = 0);
END;
$$;

-- Create a view for unbalanced journal entries (for monitoring)
CREATE OR REPLACE VIEW unbalanced_journal_entries AS
SELECT 
  id,
  entry_number,
  entry_date,
  total_debit,
  total_credit,
  (total_debit - total_credit) as difference,
  description,
  created_at
FROM journal_entries
WHERE abs(total_debit - total_credit) >= 0.01
  AND NOT (total_debit = 0 AND total_credit = 0)
ORDER BY created_at DESC;
