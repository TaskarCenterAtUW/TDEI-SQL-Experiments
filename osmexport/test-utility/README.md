# OSM-OSW Utility DB Way Exporter

This utility exports OSM XML data from a PostgreSQL database and provides tools to validate and compare the output with Azure-stored XML. It is designed for use with the TDEI schema and supports automated test cases.

## Features
- Export OSM XML for a given dataset from PostgreSQL
- Run automated test cases on the exported XML
- Compare system-generated XML with Azure-stored XML for validation

## Setup

1. **Clone the repository and navigate to the project root.**

2. **Install dependencies:**
   ```bash
   pip install -r requirements.txt
   ```

3. **Create a `.env` file in the project root with your credentials:**
   ```ini
   # Database credentials
   DB_HOST=your-db-host
   DB_PORT=5432
   DB_NAME=your-db-name
   DB_USER=your-db-user
   DB_PASSWORD=your-db-password

   # Azure Storage credentials
   AZURE_CONTAINER=your-container
   AZURE_CONNECTION_STRING=your-azure-connection-string
   ```

4. **Prepare the SQL script:**
   - Ensure `sql-script.sql` or `export_osm_xml.sql` is present in the project root.
   - The script should use `%(dataset_id1)s` and `%(dataset_id2)s` as parameters for the main export.

## Usage

### Export OSM XML for a Dataset

Run the export utility with a dataset ID:
```bash
python run_sql_export.py DATASET_ID
```
- Example:
  ```bash
  python run_sql_export.py UC5_M_20250627_100000
  ```
- The output XML will be saved in the `output/` directory as `DATASET_ID_output_YYYYMMDD_HHMMSS.xml`.
- The script will automatically run all test cases in the `test_cases/` directory on the exported XML.

### Test Cases

Test cases are Python scripts in the `test_cases/` directory. They are run automatically by `run_sql_export.py`, but can also be run manually:

- **01_xml_validity.py**: Checks XML syntax and unwanted characters.
- **02_db_xml_count_check.py**: Compares <way> and <node> counts in XML vs. DB.
- **03_width_validity.py**: Validates <tag k="width"> values in XML.
- **04_compare_system_vs_azure_xml.py**: Compares system-generated XML with Azure-stored XML for a dataset.

#### Example: Run a test case manually
```bash
python test_cases/01_xml_validity.py DATASET_ID output/DATASET_ID_output_YYYYMMDD_HHMMSS.xml
```
Or, to pipe XML via stdin:
```bash
cat output/DATASET_ID_output_YYYYMMDD_HHMMSS.xml | python test_cases/01_xml_validity.py DATASET_ID --stdin
```

### Compare with Azure-stored XML

To compare a system-generated XML file with the Azure-stored version for a dataset:
```bash
python test_cases/04_compare_system_vs_azure_xml.py DATASET_ID output/DATASET_ID_output_YYYYMMDD_HHMMSS.xml
```
Or, using stdin:
```bash
cat output/DATASET_ID_output_YYYYMMDD_HHMMSS.xml | python test_cases/04_compare_system_vs_azure_xml.py DATASET_ID --stdin
```
- The script will download the Azure XML, save it under `osm/`, and compare nodes and ways (ignoring order and IDs/refs).

## Notes
- All credentials are loaded from the `.env` file. **Never commit your `.env` file to version control.**
- The database must contain the required tables and data as expected by the SQL scripts.
- The SQL export function must return a single row with the aggregated XML string as the first column.
- The test cases directory and output directory are ignored by `.gitignore`.

## Dependencies
- Python 3.7+
- `psycopg2`
- `azure-storage-blob`
- `azure-identity`
- `python-dotenv`

Install all dependencies with:
```bash
pip install -r requirements.txt
```
