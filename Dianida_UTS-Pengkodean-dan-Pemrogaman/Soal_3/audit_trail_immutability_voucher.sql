-- =====================================================
-- 3.2 AUDIT TRAIL & IMMUTABILITY
-- Database: PostgreSQL / Supabase
-- =====================================================

-- 1. Membuat tabel voucher kas keluar
CREATE TABLE cash_disbursement_vouchers (
    voucher_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    voucher_number VARCHAR(30) NOT NULL UNIQUE,
    voucher_date DATE NOT NULL,
    description TEXT NOT NULL,
    status VARCHAR(10) NOT NULL DEFAULT 'DRAFT'
        CHECK (status IN ('DRAFT', 'POSTED')),

    created_by UUID NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    posted_by UUID,
    posted_at TIMESTAMPTZ,
    hash_checksum TEXT,

    reverses_voucher_id BIGINT
        REFERENCES cash_disbursement_vouchers(voucher_id)
);

-- 2. Membuat tabel detail jurnal
CREATE TABLE cash_disbursement_voucher_lines (
    line_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    voucher_id BIGINT NOT NULL
        REFERENCES cash_disbursement_vouchers(voucher_id),
    account_code VARCHAR(30) NOT NULL,
    account_name VARCHAR(100) NOT NULL,
    line_description TEXT,
    debit NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (debit >= 0),
    credit NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (credit >= 0),

    CHECK (NOT (debit > 0 AND credit > 0))
);

-- 3. Membuat tabel audit log
CREATE TABLE voucher_audit_log (
    audit_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    voucher_id BIGINT,
    action_type VARCHAR(30) NOT NULL,
    actor_id UUID,
    action_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    details JSONB NOT NULL DEFAULT '{}'::jsonb
);

-- 4. Mencegah perubahan atau penghapusan voucher POSTED
CREATE OR REPLACE FUNCTION prevent_change_posted_voucher()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.status = 'POSTED' THEN
        RAISE EXCEPTION
            'Voucher POSTED tidak boleh diubah atau dihapus. Gunakan jurnal pembalik.';
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_lock_posted_voucher
BEFORE UPDATE OR DELETE
ON cash_disbursement_vouchers
FOR EACH ROW
EXECUTE FUNCTION prevent_change_posted_voucher();

-- 5. Mencegah perubahan detail jurnal voucher POSTED
CREATE OR REPLACE FUNCTION prevent_change_posted_voucher_line()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_status VARCHAR(10);
    v_voucher_id BIGINT;
BEGIN
    IF TG_OP = 'INSERT' THEN
        v_voucher_id := NEW.voucher_id;
    ELSE
        v_voucher_id := OLD.voucher_id;
    END IF;

    SELECT status
    INTO v_status
    FROM cash_disbursement_vouchers
    WHERE voucher_id = v_voucher_id
    FOR UPDATE;

    IF v_status = 'POSTED' THEN
        RAISE EXCEPTION
            'Detail voucher POSTED tidak boleh diubah atau dihapus.';
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_lock_posted_voucher_line
BEFORE INSERT OR UPDATE OR DELETE
ON cash_disbursement_voucher_lines
FOR EACH ROW
EXECUTE FUNCTION prevent_change_posted_voucher_line();

-- 6. Mencatat aktivitas voucher ke audit log
CREATE OR REPLACE FUNCTION log_voucher_activity()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_id BIGINT;
    v_actor UUID;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_id := OLD.voucher_id;
        v_actor := OLD.created_by;
    ELSE
        v_id := NEW.voucher_id;
        v_actor := NEW.created_by;
    END IF;

    INSERT INTO voucher_audit_log (
        voucher_id,
        action_type,
        actor_id,
        details
    )
    VALUES (
        v_id,
        TG_OP,
        v_actor,
        jsonb_build_object(
            'old_status',
            CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE OLD.status END,
            'new_status',
            CASE WHEN TG_OP = 'DELETE' THEN NULL ELSE NEW.status END
        )
    );

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_audit_voucher_activity
AFTER INSERT OR UPDATE OR DELETE
ON cash_disbursement_vouchers
FOR EACH ROW
EXECUTE FUNCTION log_voucher_activity();

-- 7. Validasi debit dan kredit sebelum posting
CREATE OR REPLACE FUNCTION post_cash_disbursement_voucher(
    p_voucher_id BIGINT,
    p_posted_by UUID,
    p_hash_checksum TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_status VARCHAR(10);
    v_debit NUMERIC(18,2);
    v_credit NUMERIC(18,2);
    v_count INTEGER;
BEGIN
    SELECT status
    INTO v_status
    FROM cash_disbursement_vouchers
    WHERE voucher_id = p_voucher_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Voucher tidak ditemukan.';
    END IF;

    IF v_status <> 'DRAFT' THEN
        RAISE EXCEPTION
            'Hanya voucher DRAFT yang dapat di-posting.';
    END IF;

    SELECT
        COALESCE(SUM(debit), 0),
        COALESCE(SUM(credit), 0),
        COUNT(*)
    INTO v_debit, v_credit, v_count
    FROM cash_disbursement_voucher_lines
    WHERE voucher_id = p_voucher_id;

    IF v_count = 0 THEN
        RAISE EXCEPTION
            'Voucher harus memiliki minimal satu baris jurnal.';
    END IF;

    IF v_debit <> v_credit THEN
        RAISE EXCEPTION
            'Total debit harus sama dengan total kredit.';
    END IF;

    IF p_hash_checksum IS NULL
       OR LENGTH(TRIM(p_hash_checksum)) = 0 THEN
        RAISE EXCEPTION
            'Hash checksum wajib diisi.';
    END IF;

    UPDATE cash_disbursement_vouchers
    SET status = 'POSTED',
        posted_by = p_posted_by,
        posted_at = CURRENT_TIMESTAMP,
        hash_checksum = p_hash_checksum
    WHERE voucher_id = p_voucher_id;
END;
$$;

-- =====================================================
-- KETERANGAN FIELD AUDIT
-- created_by     : identitas pembuat voucher
-- created_at     : waktu pembuatan voucher
-- hash_checksum  : hash untuk memeriksa integritas data
--
-- Transaksi POSTED tidak boleh diedit atau dihapus.
-- Koreksi dilakukan dengan membuat voucher pembalik baru
-- yang mengisi reverses_voucher_id dengan ID voucher asli.
-- =====================================================