/*
  # Fix Journal Entry Creation by Using 0,0 Initial Totals
  
  1. Root Cause
    - Triggers create journal_entry with correct total_debit/total_credit
    - Then insert journal_entry_lines one by one
    - After EACH line insert, recalculate_journal_entry_totals() trigger runs
    - This updates totals based on partial lines, causing constraint violation
  
  2. Solution
    - Create journal_entry with total_debit=0, total_credit=0 (allowed by constraint)
    - Insert all journal_entry_lines
    - Let recalculate_journal_entry_totals() trigger calculate final totals
  
  3. Changes
    - Update post_sales_invoice_journal() to use 0,0
    - Update post_receipt_voucher_journal() to use 0,0
    - Update post_payment_voucher_journal() to use 0,0
*/

-- ============================================
-- Sales Invoice Journal Trigger
-- ============================================
CREATE OR REPLACE FUNCTION post_sales_invoice_journal()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_je_id UUID;
  v_je_number TEXT;
  v_ar_account_id UUID;
  v_sales_account_id UUID;
  v_ppn_account_id UUID;
  v_cogs_account_id UUID;
  v_inventory_account_id UUID;
  v_total_cogs DECIMAL(18,2) := 0;
  v_item_record RECORD;
  v_sales_amount DECIMAL(18,2);
BEGIN
  IF TG_OP = 'INSERT' OR (TG_OP = 'UPDATE' AND OLD.journal_entry_id IS NULL AND NEW.payment_status IN ('pending', 'partial', 'paid')) THEN

    -- Get account IDs
    SELECT id INTO v_ar_account_id FROM chart_of_accounts WHERE code = '1120' LIMIT 1;
    SELECT id INTO v_sales_account_id FROM chart_of_accounts WHERE code = '4100' LIMIT 1;
    SELECT id INTO v_ppn_account_id FROM chart_of_accounts WHERE code = '2130' LIMIT 1;
    SELECT id INTO v_cogs_account_id FROM chart_of_accounts WHERE code = '5100' LIMIT 1;
    SELECT id INTO v_inventory_account_id FROM chart_of_accounts WHERE code = '1130' LIMIT 1;

    IF v_ar_account_id IS NULL OR v_sales_account_id IS NULL THEN
      RETURN NEW;
    END IF;

    -- Calculate sales amount after discount
    v_sales_amount := NEW.subtotal - COALESCE(NEW.discount_amount, 0);

    -- Generate journal entry number
    v_je_number := 'JE' || TO_CHAR(NEW.invoice_date, 'YYMM') || '-' || LPAD((
      SELECT COUNT(*) + 1 FROM journal_entries WHERE entry_number LIKE 'JE' || TO_CHAR(NEW.invoice_date, 'YYMM') || '%'
    )::TEXT, 4, '0');

    -- Create journal entry with 0,0 totals (will be recalculated by trigger)
    INSERT INTO journal_entries (
      entry_number, entry_date, source_module, reference_id, reference_number,
      description, total_debit, total_credit, is_posted, posted_by
    ) VALUES (
      v_je_number, NEW.invoice_date, 'sales_invoice', NEW.id, NEW.invoice_number,
      'Sales Invoice: ' || NEW.invoice_number, 0, 0, true, NEW.created_by
    ) RETURNING id INTO v_je_id;

    -- Dr: Accounts Receivable
    INSERT INTO journal_entry_lines (
      journal_entry_id, line_number, account_id, debit, credit, description, customer_id
    ) VALUES (
      v_je_id, 1, v_ar_account_id, NEW.total_amount, 0,
      'Invoice ' || NEW.invoice_number, NEW.customer_id
    );

    -- Cr: Sales Revenue (after discount)
    INSERT INTO journal_entry_lines (
      journal_entry_id, line_number, account_id, debit, credit, description
    ) VALUES (
      v_je_id, 2, v_sales_account_id, 0, v_sales_amount,
      'Sales Revenue - ' || NEW.invoice_number
    );

    -- Cr: PPN (Tax Payable) if any
    IF NEW.tax_amount > 0 AND v_ppn_account_id IS NOT NULL THEN
      INSERT INTO journal_entry_lines (
        journal_entry_id, line_number, account_id, debit, credit, description
      ) VALUES (
        v_je_id, 3, v_ppn_account_id, 0, NEW.tax_amount,
        'PPN 11% - ' || NEW.invoice_number
      );
    END IF;

    -- Link journal entry
    NEW.journal_entry_id := v_je_id;

    -- ================================================
    -- ENTRY 2: COST OF GOODS SOLD
    -- ================================================

    IF v_cogs_account_id IS NOT NULL AND v_inventory_account_id IS NOT NULL THEN
      -- Calculate total COGS
      FOR v_item_record IN
        SELECT 
          sii.quantity,
          COALESCE(b.purchase_price, 0) as cost_per_unit,
          (sii.quantity * COALESCE(b.purchase_price, 0)) as total_cost
        FROM sales_invoice_items sii
        LEFT JOIN batches b ON b.id = sii.batch_id
        WHERE sii.invoice_id = NEW.id
      LOOP
        v_total_cogs := v_total_cogs + v_item_record.total_cost;
      END LOOP;

      -- Only post COGS entry if there's actual cost
      IF v_total_cogs > 0 THEN
        v_je_number := 'JE' || TO_CHAR(NEW.invoice_date, 'YYMM') || '-' || LPAD((
          SELECT COUNT(*) + 1 FROM journal_entries WHERE entry_number LIKE 'JE' || TO_CHAR(NEW.invoice_date, 'YYMM') || '%'
        )::TEXT, 4, '0');

        -- Create COGS journal entry with 0,0 totals
        INSERT INTO journal_entries (
          entry_number, entry_date, source_module, reference_id, reference_number,
          description, total_debit, total_credit, is_posted, posted_by
        ) VALUES (
          v_je_number, NEW.invoice_date, 'sales_invoice_cogs', NEW.id, NEW.invoice_number,
          'COGS for Sales Invoice: ' || NEW.invoice_number, 0, 0, true, NEW.created_by
        ) RETURNING id INTO v_je_id;

        -- Dr: COGS
        INSERT INTO journal_entry_lines (
          journal_entry_id, line_number, account_id, debit, credit, description, customer_id
        ) VALUES (
          v_je_id, 1, v_cogs_account_id, v_total_cogs, 0,
          'COGS - ' || NEW.invoice_number, NEW.customer_id
        );

        -- Cr: Inventory
        INSERT INTO journal_entry_lines (
          journal_entry_id, line_number, account_id, debit, credit, description
        ) VALUES (
          v_je_id, 2, v_inventory_account_id, 0, v_total_cogs,
          'Inventory Reduction - ' || NEW.invoice_number
        );
      END IF;
    END IF;

  END IF;

  RETURN NEW;
END;
$$;

-- ============================================
-- Receipt Voucher Journal Trigger
-- ============================================
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
      SELECT coa_id INTO v_debit_account_id
      FROM bank_accounts
      WHERE id = NEW.bank_account_id;

      IF v_debit_account_id IS NULL THEN
        SELECT id INTO v_debit_account_id FROM chart_of_accounts WHERE code = '1111' LIMIT 1;
      END IF;
    ELSIF NEW.payment_method = 'cash' THEN
      SELECT id INTO v_debit_account_id FROM chart_of_accounts WHERE code = '1101' LIMIT 1;
    ELSE
      SELECT id INTO v_debit_account_id FROM chart_of_accounts WHERE code = '1111' LIMIT 1;
    END IF;

    -- Get Accounts Receivable account
    SELECT id INTO v_ar_account_id FROM chart_of_accounts WHERE code = '1120' LIMIT 1;

    IF v_debit_account_id IS NULL OR v_ar_account_id IS NULL THEN
      RETURN NEW;
    END IF;

    -- Generate journal entry number
    v_je_number := 'JE' || TO_CHAR(NEW.voucher_date, 'YYMM') || '-' || LPAD((
      SELECT COUNT(*) + 1 FROM journal_entries WHERE entry_number LIKE 'JE' || TO_CHAR(NEW.voucher_date, 'YYMM') || '%'
    )::TEXT, 4, '0');

    -- Create journal entry with 0,0 totals
    INSERT INTO journal_entries (
      entry_number, entry_date, source_module, reference_id, reference_number,
      description, total_debit, total_credit, is_posted, posted_by
    ) VALUES (
      v_je_number, NEW.voucher_date, 'receipt', NEW.id, NEW.voucher_number,
      'Receipt Voucher: ' || NEW.voucher_number,
      0, 0, true, NEW.created_by
    ) RETURNING id INTO v_je_id;

    -- Debit: Cash/Bank Account
    INSERT INTO journal_entry_lines (journal_entry_id, line_number, account_id, description, debit, credit, customer_id)
    VALUES (v_je_id, 1, v_debit_account_id, 'Cash Receipt - ' || NEW.voucher_number, NEW.amount, 0, NEW.customer_id);

    -- Credit: Accounts Receivable
    INSERT INTO journal_entry_lines (journal_entry_id, line_number, account_id, description, debit, credit, customer_id)
    VALUES (v_je_id, 2, v_ar_account_id, 'A/R Payment - ' || NEW.voucher_number, 0, NEW.amount, NEW.customer_id);

    -- Link journal entry
    NEW.journal_entry_id := v_je_id;
  END IF;

  RETURN NEW;
END;
$$;

-- ============================================
-- Payment Voucher Journal Trigger
-- ============================================
CREATE OR REPLACE FUNCTION post_payment_voucher_journal()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_je_id UUID;
  v_je_number TEXT;
  v_credit_account_id UUID;
  v_ap_account_id UUID;
  v_pph_account_id UUID;
  v_net_amount DECIMAL(18,2);
BEGIN
  IF TG_OP = 'INSERT' THEN

    -- Determine the credit account (cash/bank)
    IF NEW.bank_account_id IS NOT NULL THEN
      SELECT coa_id INTO v_credit_account_id
      FROM bank_accounts
      WHERE id = NEW.bank_account_id;

      IF v_credit_account_id IS NULL THEN
        SELECT id INTO v_credit_account_id FROM chart_of_accounts WHERE code = '1111' LIMIT 1;
      END IF;
    ELSIF NEW.payment_method = 'cash' THEN
      SELECT id INTO v_credit_account_id FROM chart_of_accounts WHERE code = '1101' LIMIT 1;
    ELSE
      SELECT id INTO v_credit_account_id FROM chart_of_accounts WHERE code = '1111' LIMIT 1;
    END IF;

    -- Get other accounts
    SELECT id INTO v_ap_account_id FROM chart_of_accounts WHERE code = '2110' LIMIT 1;
    SELECT id INTO v_pph_account_id FROM chart_of_accounts WHERE code = '2132' LIMIT 1;

    IF v_credit_account_id IS NULL OR v_ap_account_id IS NULL THEN
      RETURN NEW;
    END IF;

    v_net_amount := NEW.amount - COALESCE(NEW.pph_amount, 0);

    -- Generate journal entry number
    v_je_number := 'JE' || TO_CHAR(NEW.voucher_date, 'YYMM') || '-' || LPAD((
      SELECT COUNT(*) + 1 FROM journal_entries WHERE entry_number LIKE 'JE' || TO_CHAR(NEW.voucher_date, 'YYMM') || '%'
    )::TEXT, 4, '0');

    -- Create journal entry with 0,0 totals
    INSERT INTO journal_entries (
      entry_number, entry_date, source_module, reference_id, reference_number,
      description, total_debit, total_credit, is_posted, posted_by
    ) VALUES (
      v_je_number, NEW.voucher_date, 'payment', NEW.id, NEW.voucher_number,
      'Payment Voucher: ' || NEW.voucher_number,
      0, 0, true, NEW.created_by
    ) RETURNING id INTO v_je_id;

    -- Debit: Accounts Payable
    INSERT INTO journal_entry_lines (journal_entry_id, line_number, account_id, description, debit, credit, supplier_id)
    VALUES (v_je_id, 1, v_ap_account_id, 'A/P Payment - ' || NEW.voucher_number, NEW.amount, 0, NEW.supplier_id);

    -- Credit: Withholding Tax PPh (if applicable)
    IF NEW.pph_amount > 0 AND v_pph_account_id IS NOT NULL THEN
      INSERT INTO journal_entry_lines (journal_entry_id, line_number, account_id, description, debit, credit, supplier_id)
      VALUES (v_je_id, 2, v_pph_account_id, 'PPh Withholding - ' || NEW.voucher_number, 0, NEW.pph_amount, NEW.supplier_id);
    END IF;

    -- Credit: Cash/Bank Account (net amount)
    INSERT INTO journal_entry_lines (journal_entry_id, line_number, account_id, description, debit, credit, supplier_id)
    VALUES (v_je_id, 3, v_credit_account_id, 'Cash Payment - ' || NEW.voucher_number, 0, v_net_amount, NEW.supplier_id);

    -- Link journal entry
    NEW.journal_entry_id := v_je_id;
  END IF;

  RETURN NEW;
END;
$$;
