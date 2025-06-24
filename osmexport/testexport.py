import psycopg2                                                              
import sys
import os
 
# --- STEP 1: Connect to DB (edit these details) ---
conn = psycopg2.connect(
  host="tdei.postgres.database.azure.com",
  port=5432,
  dbname="tdei",
  user="bill",
  password=<ENTER PWD>
)

# --- STEP 2: Run the hardcoded ZIP query ---
query = """
SELECT string_agg(line, E'\n') AS osm_output
FROM content.exportdata;
"""
 
# --- STEP 3: Open cursor and fetch rows one-by-one ---
cur = conn.cursor(name="osm_export_cursor")  # server-side cursor to stream
cur.execute(query)

for row in cur:
    sys.stdout.write(row[0])

cur.close()
conn.close()
