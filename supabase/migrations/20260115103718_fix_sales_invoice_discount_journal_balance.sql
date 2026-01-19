/*
  # Fix Sales Invoice Journal Entry Balance with Discount
  
  1. Problem
    - When invoice has discount, journal entry becomes unbalanced
    - Current: Dr AR = total_amount, Cr Sales = subtotal, Cr PPN = tax
    - If discount exists: total_amount = subtotal - discount + tax
    - This creates imbalance: debit ≠ credit by discount amount
  
  2. Solution
    - Adjust Sales credit to account for discount
    - Sales should be credited for: subtotal - discount
    - This ensures: Dr AR (total) = Cr Sales (subtotal - discount) + Cr PPN (tax)
  
  3. Accounting Treatment
    - Discount reduces the Sales Revenue directly
    - No separate discount account needed
    - AR reflects net amount customer owes
*/

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
  -- Only post on insert or when status changes to 'unpaid' or 'partial'
  IF TG_OP = 'INSERT' OR (TG_OP = 'UPDATE' AND OLD.journal_entry_id IS NULL AND NEW.status IN ('unpaid', 'partial', 'paid')) THEN

    -- Get account IDs
    SELECT id INTO v_ar_account_id FROM chart_of_accounts WHERE code = '1120' LIMIT 1;
    SELECT id INTO v_sales_account_id FROM chart_of_accounts WHERE code = '4100' LIMIT 1;
    SELECT id INTO v_ppn_account_id FROM chart_of_accounts WHERE code = '2130' LIMIT 1;
    SELECT id INTO v_cogs_account_id FROM chart_of_accounts WHERE code = '5100' LIMIT 1;
    SELECT id INTO v_inventory_account_id FROM chart_of_accounts WHERE code = '1130' LIMIT 1;

    IF v_ar_account_id IS NULL OR v_sales_account_id IS NULL THEN
      RETURN NEW;
    END IF;

    -- ================================================
    -- ENTRY 1: REVENUE RECOGNITION (AR, Sales, PPN)
    -- ================================================

    -- Calculate sales amount after discount
    v_sales_amount := NEW.subtotal - COALESCE(NEW.discount_amount, 0);

    -- Generate journal entry number
    v_je_number := 'JE' || TO_CHAR(CURRENT_DATE, 'YYMM') || '-' || LPAD((
      SELECT COUNT(*) + 1 FROM journal_entries WHERE entry_number LIKE 'JE' || TO_CHAR(CURRENT_DATE, 'YYMM') || '%'
    )::TEXT, 4, '0');

    -- Create journal entry for revenue
    INSERT INTO journal_entries (
      entry_number, entry_date, source_module, reference_id, reference_number,
      description, total_debit, total_credit, is_posted, posted_by
    ) VALUES (
      v_je_number, NEW.invoice_date, 'sales_invoice', NEW.id, NEW.invoice_number,
      'Sales Invoice: ' || NEW.invoice_number,
      NEW.total_amount, NEW.total_amount, true, NEW.created_by
    ) RETURNING id INTO v_je_id;

    -- Debit: Accounts Receivable
    INSERT INTO journal_entry_lines (journal_entry_id, line_number, account_id, description, debit, credit, customer_id)
    VALUES (v_je_id, 1, v_ar_account_id, 'A/R - ' || NEW.invoice_number, NEW.total_amount, 0, NEW.customer_id);

    -- Credit: Sales Revenue (subtotal minus discount)
    INSERT INTO journal_entry_lines (journal_entry_id, line_number, account_id, description, debit, credit, customer_id)
    VALUES (v_je_id, 2, v_sales_account_id, 'Sales - ' || NEW.invoice_number, 0, v_sales_amount, NEW.customer_id);

    -- Credit: PPN Output (if applicable)
    IF NEW.tax_amount > 0 AND v_ppn_account_id IS NOT NULL THEN
      INSERT INTO journal_entry_lines (journal_entry_id, line_number, account_id, description, debit, credit, customer_id)
      VALUES (v_je_id, 3, v_ppn_account_id, 'PPN Output - ' || NEW.invoice_number, 0, NEW.tax_amount, NEW.customer_id);
    END IF;

    -- Update sales invoice with journal entry ID
    NEW.journal_entry_id := v_je_id;

    -- ================================================
    -- ENTRY 2: COGS RECOGNITION (COGS, Inventory)
    -- ================================================

    IF v_cogs_account_id IS NOT NULL AND v_inventory_account_id IS NOT NULL THEN
      -- Calculate total COGS from all invoice items
      FOR v_item_record IN
        SELECT
          sii.quantity,
          sii.batch_id,
          COALESCE(b.cost_per_unit, 0) as cost_per_unit
        FROM sales_invoice_items sii
        LEFT JOIN batches b ON sii.batch_id = b.id
        WHERE sii.invoice_id = NEW.id
      LOOP
        v_total_cogs := v_total_cogs + (v_item_record.quantity * v_item_record.cost_per_unit);
      END LOOP;

      -- Only create COGS entry if there's actual cost
      IF v_total_cogs > 0 THEN
        -- Generate new journal entry number for COGS
        v_je_number := 'JE' || TO_CHAR(CURRENT_DATE, 'YYMM') || '-' || LPAD((
          SELECT COUNT(*) + 1 FROM journal_entries WHERE entry_number LIKE 'JE' || TO_CHAR(CURRENT_DATE, 'YYMM') || '%'
        )::TEXT, 4, '0');

        -- Create journal entry for COGS
        INSERT INTO journal_entries (
          entry_number, entry_date, source_module, reference_id, reference_number,
          description, total_debit, total_credit, is_posted, posted_by
        ) VALUES (
          v_je_number, NEW.invoice_date, 'sales_invoice_cogs', NEW.id, NEW.invoice_number,
          'COGS for Sales Invoice: ' || NEW.invoice_number,
          v_total_cogs, v_total_cogs, true, NEW.created_by
        );

        -- Get the new journal entry ID
        SELECT id INTO v_je_id FROM journal_entries WHERE entry_number = v_je_number;

        -- Debit: COGS
        INSERT INTO journal_entry_lines (journal_entry_id, line_number, account_id, description, debit, credit, customer_id)
        VALUES (v_je_id, 1, v_cogs_account_id, 'COGS - ' || NEW.invoice_number, v_total_cogs, 0, NEW.customer_id);

        -- Credit: Inventory
        INSERT INTO journal_entry_lines (journal_entry_id, line_number, account_id, description, debit, credit)
        VALUES (v_je_id, 2, v_inventory_account_id, 'Inventory - ' || NEW.invoice_number, 0, v_total_cogs);
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION post_sales_invoice_journal IS
'Posts sales invoice to accounting with discount handling. Sales credit = subtotal - discount. This ensures Dr AR (total) = Cr Sales (net) + Cr PPN (tax).';
