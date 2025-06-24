import psycopg2
import zipfile
import os

# --- STEP 1: Connect to DB (edit these details) ---
conn = psycopg2.connect(
    host="tdei.postgres.database.azure.com",
    port=5432,
    dbname="tdei",
    user="bill",
    password="b1ll"
)

# --- STEP 2: Run the hardcoded ZIP query ---
query = """
SELECT * FROM (
  VALUES
    (
      0,
      -- Local file header (30 bytes)
      decode(
        '504b03041400000000000000ecb70c53' ||  -- Signature + version + flags + compression + time/date + CRC32
        '0e0000000e00000009000000',           -- compressed/uncompressed size (14), filename len (9), extra len (0)
        'hex'
      ) || 'hello.txt'::bytea                -- 9-byte filename
        || 'Hello, world!' || E'\n'::bytea   -- 14-byte file contents (LF at end)
    ),
    (
      1,
      -- Central directory entry (46 bytes)
      decode(
        '504b0102140014000000000000ecb70c53' ||  -- Signature + versions + flags + compression + time/date + CRC32
        '0e0000000e00000009000000' ||            -- compressed/uncompressed size (14), filename len (9), extra/comment (0)
        '0000000000000000' ||                    -- disk #, internal/external attrs
        '00000000',                              -- relative offset of local header (0)
        'hex'
      ) || 'hello.txt'::bytea                   -- 9-byte filename
    ),
    (
      2,
      -- EOCD (End of central directory)
      decode(
        '504b050600000000010001001f0000001d0000000000',
        'hex'
      )
    )
) AS parts(ord, part)
ORDER BY ord;
"""


# --- STEP 3: Open cursor and fetch rows one-by-one ---
cur = conn.cursor(name="zip_stream_cursor")  # server-side cursor to stream
cur.execute(query)

output_file = "output.zip"

# --- STEP 4: Write chunks to file (raw bytes, no newlines) ---
with open(output_file, "wb") as f:
    for row in cur:
        f.write(bytes(row[0]))

cur.close()
conn.close()

# --- STEP 5: Test the ZIP file ---
try:
    with zipfile.ZipFile(output_file, 'r') as z:
        test = z.testzip()
        if test is None:
            print("✅ ZIP file is valid. Contents:")
            print(z.namelist())
        else:
            print(f"❌ Corrupted file in archive: {test}")
except zipfile.BadZipFile:
    print("❌ Not a valid ZIP file")
    raise

# Optional: Clean up
# os.remove(output_file)

