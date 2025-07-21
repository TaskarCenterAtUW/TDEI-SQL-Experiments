import sys
import argparse
import xml.etree.ElementTree as ET

def main():
    parser = argparse.ArgumentParser(description='Check validity of <tag k="width"> values in XML.')
    parser.add_argument('dataset_id', help='Dataset ID (not used, for interface consistency)')
    parser.add_argument('xml_file', nargs='?', help='Path to XML output file (optional if --stdin is used)')
    parser.add_argument('--stdin', action='store_true', help='Read XML from stdin')
    args = parser.parse_args()

    # Read XML
    if args.stdin:
        xml_content = sys.stdin.read()
    elif args.xml_file:
        with open(args.xml_file, 'r', encoding='utf-8') as f:
            xml_content = f.read()
    else:
        print('No XML input provided.')
        sys.exit(1)

    try:
        xml_content = xml_content.replace("&", "").replace('"', "'")
        root = ET.fromstring(xml_content)
    except ET.ParseError as e:
        print(f"Failed to parse XML: {e}")
        sys.exit(1)

    width_tags = root.findall(".//tag[@k='width']")
    
    if not width_tags:
        print("[INFO] No <tag k='width'> found in the XML. Test skipped.")
        sys.exit(0)

    all_passed = True
    for i, tag in enumerate(width_tags, 1):
        value = tag.get('v', '').strip()
        
        # Check 1: Value is not empty
        if value == '':
            print(f"[FAIL] Width tag #{i} has an empty value.")
            all_passed = False
            continue

        # Check 2: Value is a valid float
        try:
            float_val = float(value)
        except ValueError:
            print(f"[FAIL] Width tag #{i} value is not a valid float: '{value}'")
            all_passed = False
            continue

        # Check 3: Value is not NaN
        if float_val != float_val:
            print(f"[FAIL] Width tag #{i} value is NaN: '{value}'")
            all_passed = False
            continue
    
    if all_passed:
        print(f"[PASS] All {len(width_tags)} <tag k='width'> values are valid.")
    else:
        sys.exit(1)

if __name__ == '__main__':
    main() 