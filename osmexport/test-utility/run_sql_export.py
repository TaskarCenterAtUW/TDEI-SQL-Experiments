import argparse
import os
import sys
import psycopg2
from datetime import datetime
import subprocess
from dotenv import load_dotenv

# For colorized output
class Colors:
    GREEN = '\033[92m'
    RED = '\033[91m'
    YELLOW = '\033[93m'
    BOLD = '\033[1m'
    ENDC = '\033[0m'

# --- CONFIGURE THESE ---
load_dotenv()
DB_CONFIG = {
    'host': os.environ.get('DB_HOST'),
    'port': int(os.environ.get('DB_PORT', 5432)),
    'dbname': os.environ.get('DB_NAME'),
    'user': os.environ.get('DB_USER'),
    'password': os.environ.get('DB_PASSWORD')
}
OUTPUT_DIR = 'output'
TEST_CASES_DIR = 'test_cases'


def export_xml(dataset_id):
    sql = 'SELECT content.export_osm_xml(%s);'
    params = (dataset_id,)
    try:
        conn = psycopg2.connect(**DB_CONFIG)
        cur = conn.cursor()
        cur.execute(sql, params)
        result = cur.fetchone()
        if not result or not result[0]:
            print(f"{Colors.RED}No data returned from DB for dataset {dataset_id}.{Colors.ENDC}")
            sys.exit(1)
        xml_data = result[0]
    except Exception as e:
        print(f'{Colors.RED}DB Error: {e}{Colors.ENDC}')
        sys.exit(1)
    finally:
        if 'cur' in locals():
            cur.close()
        if 'conn' in locals():
            conn.close()
    now_str = datetime.now().strftime('%Y%m%d_%H%M%S')
    filename = f"{dataset_id}_output_{now_str}.xml"
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    output_path = os.path.join(OUTPUT_DIR, filename)
    with open(output_path, 'w', encoding='utf-8') as f:
        f.write(xml_data)
    print(f'Success! Output written to {Colors.BOLD}{output_path}{Colors.ENDC}')
    return output_path, xml_data


def run_test_cases(dataset_id, xml_file, xml_content):
    if not os.path.isdir(TEST_CASES_DIR):
        print(f'{Colors.YELLOW}Warning: Test cases directory not found at \'{TEST_CASES_DIR}\'{Colors.ENDC}')
        return
        
    test_files = [f for f in os.listdir(TEST_CASES_DIR) if f.endswith('.py')]
    test_files.sort()
    
    if not test_files:
        print(f'{Colors.YELLOW}Warning: No test case scripts found in \'{TEST_CASES_DIR}\'{Colors.ENDC}')
        return

    print(f'\n{Colors.BOLD}Running tests for dataset: {dataset_id}{Colors.ENDC}')
    print('=' * 50)
    
    total_tests = len(test_files)
    passed_tests = 0

    for i, test_file in enumerate(test_files, 1):
        test_path = os.path.join(TEST_CASES_DIR, test_file)
        print(f'[{i}/{total_tests}] Running test: {Colors.BOLD}{test_file}{Colors.ENDC}')
        
        result = subprocess.run(
            [sys.executable, test_path, dataset_id, '--stdin'],
            input=xml_content,
            capture_output=True,
            text=True
        )
        
        if result.stdout:
            for line in result.stdout.strip().split('\n'):
                print(f'  {line}')
        
        if result.returncode == 0:
            print(f'  Result: {Colors.GREEN}{Colors.BOLD}PASS{Colors.ENDC}')
            passed_tests += 1
        else:
            if result.stderr:
                for line in result.stderr.strip().split('\n'):
                    print(f'  {Colors.RED}{line}{Colors.ENDC}')
            print(f'  Result: {Colors.RED}{Colors.BOLD}FAIL{Colors.ENDC}')
            print('\n' + '=' * 50)
            print(f'{Colors.RED}{Colors.BOLD}Stopping tests due to failure.{Colors.ENDC}')
            break
            
    print('=' * 50)
    if passed_tests == total_tests:
        print(f'{Colors.GREEN}{Colors.BOLD}All {total_tests} tests passed!{Colors.ENDC}')
    else:
        print(f'{Colors.YELLOW}Summary: {passed_tests}/{total_tests} tests passed.{Colors.ENDC}')


def main():
    parser = argparse.ArgumentParser(description='Export OSM XML from DB for a dataset ID and run test cases.')
    parser.add_argument('dataset_id', help='Dataset ID (e.g., UC5_M_20250627_100000)')
    args = parser.parse_args()
    xml_file, xml_content = export_xml(args.dataset_id)
    run_test_cases(args.dataset_id, xml_file, xml_content)


if __name__ == '__main__':
    main() 