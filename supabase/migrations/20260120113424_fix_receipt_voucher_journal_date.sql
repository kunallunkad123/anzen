/*
  # Fix Receipt Voucher Journal Entry Date Issue
  
  1. Problem
    - Receipt voucher journal function uses CURRENT_DATE instead of voucher_date for JE numbering
    - This should use the voucher_date to match the invoice date
  
  2. Solution
    - Update to use NEW.voucher_date consistently
*/

CREATE OR REPLACE FUNCTION post_receipt_voucher_journal()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_je_id UUID;
  v_je_number TEXT;
  v_debit_account_id UUID;
  v_ar_account_id UUID;
BEGIN
  IF TG_OP = 'INSERT' THEN

    -- Determine the debit account (cash/bank)
    IF NEW.bank_account_id IS NOT NULL THEN
      -- Use the specific bank account's linked COA
      SELECT coa_id INTO v_debit_account_id
      FROM bank_accounts
      WHERE id = NEW.bank_account_id;

      -- If bank account doesn't have a linked COA, fall back to generic bank account
      IF v_debit_account_id IS NULL THEN
        SELECT id INTO v_debit_account_id FROM chart_of_accounts WHERE code = '1111' LIMIT 1;
      END IF;
    ELSIF NEW.payment_method = 'cash' THEN
      -- Cash payment
      SELECT id INTO v_debit_account_id FROM chart_of_accounts WHERE code = '1101' LIMIT 1;
    ELSE
      -- Generic bank account as fallback
      SELECT id INTO v_debit_account_id FROM chart_of_accounts WHERE code = '1111' LIMIT 1;
    END IF;

    -- Get Accounts Receivable account
    SELECT id INTO v_ar_account_id FROM chart_of_accounts WHERE code = '1120' LIMIT 1;

    IF v_debit_account_id IS NULL OR v_ar_account_id IS NULL THEN
      RETURN NEW;
    END IF;

    -- Generate journal entry number using voucher_date (not CURRENT_DATE)
    v_je_number := 'JE' || TO_CHAR(NEW.voucher_date, 'YYMM') || '-' || LPAD((
      SELECT COUNT(*) + 1 FROM journal_entries WHERE entry_number LIKE 'JE' || TO_CHAR(NEW.voucher_date, 'YYMM') || '%'
    )::TEXT, 4, '0');

    -- Create journal entry
    INSERT INTO journal_entries (
      entry_number, entry_date, source_module, reference_id, reference_number,
      description, total_debit, total_credit, is_posted, posted_by
    ) VALUES (
      v_je_number, NEW.voucher_date, 'receipt', NEW.id, NEW.voucher_number,
      'Receipt Voucher: ' || NEW.voucher_number,
      NEW.amount, NEW.amount, true, NEW.created_by
    ) RETURNING id INTO v_je_id;

    -- Debit: Cash/Specific Bank Account
    INSERT INTO journal_entry_lines (journal_entry_id, line_number, account_id, description, debit, credit, customer_id)
    VALUES (v_je_id, 1, v_debit_account_id, 'Cash Receipt - ' || NEW.voucher_number, NEW.amount, 0, NEW.customer_id);

    -- Credit: Accounts Receivable
    INSERT INTO journal_entry_lines (journal_entry_id, line_number, account_id, description, debit, credit, customer_id)
    VALUES (v_je_id, 2, v_ar_account_id, 'A/R Payment - ' || NEW.voucher_number, 0, NEW.amount, NEW.customer_id);

    -- Link journal entry to voucher
    NEW.journal_entry_id := v_je_id;
  END IF;

  RETURN NEW;
END;
$$;
