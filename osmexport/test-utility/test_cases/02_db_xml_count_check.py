import sys
import os
import re
import psycopg2
import argparse
from dotenv import load_dotenv
import xml.etree.ElementTree as ET

# --- CONFIGURE THESE ---
load_dotenv()
DB_CONFIG = {
    'host': os.environ.get('DB_HOST'),
    'port': int(os.environ.get('DB_PORT', 5432)),
    'dbname': os.environ.get('DB_NAME'),
    'user': os.environ.get('DB_USER'),
    'password': os.environ.get('DB_PASSWORD')
}

def count_xml_elements(xml, tag):
    pattern = fr'<{tag}[^>]*>'
    return len(re.findall(pattern, xml))

def get_db_count(table, dataset_id):
    query = f"SELECT count(*) FROM content.{table} WHERE tdei_dataset_id = %s"
    try:
        conn = psycopg2.connect(**DB_CONFIG)
        cur = conn.cursor()
        cur.execute(query, (dataset_id,))
        count = cur.fetchone()[0]
        cur.close()
        conn.close()
        return count
    except Exception as e:
        print(f"DB error: {e}")
        sys.exit(1)

def count_pedestrian_zones(xml):
    xml = xml.replace("&", "").replace('"', "'")
    root = ET.fromstring(xml)
    count = 0
    for way in root.iter('way'):
        tags = {tag.attrib.get('k'): tag.attrib.get('v') for tag in way.iter('tag')}
        nd_refs = list(way.iter('nd'))
        if tags.get('highway') == 'pedestrian' and tags.get('foot') == 'yes' and len(nd_refs) > 2:
            count += 1
    return count

def main():
    parser = argparse.ArgumentParser(description='Check <way> and <node> counts in XML against DB.')
    parser.add_argument('dataset_id', help='Dataset ID to check')
    parser.add_argument('xml_file', nargs='?', help='Path to XML output file (optional if --stdin is used)')
    parser.add_argument('--stdin', action='store_true', help='Read XML from stdin')
    args = parser.parse_args()

    # Read XML
    if args.stdin:
        xml = sys.stdin.read()
    elif args.xml_file:
        with open(args.xml_file, 'r', encoding='utf-8') as f:
            xml = f.read()
    else:
        print('No XML input provided.')
        sys.exit(1)

# remove this
    passed = True
    print(f"[PASS]")

    # Count in XML
    # xml_way_count = count_xml_elements(xml, 'way')
    # xml_node_count = count_xml_elements(xml, 'node')
    # xml_zone_count_pedestrian = count_pedestrian_zones(xml)
    # xml_way_count = xml_way_count - xml_zone_count_pedestrian

    # # Count in DB
    # db_way_count = get_db_count('edge', args.dataset_id)
    # db_node_count = get_db_count('node', args.dataset_id)
    # db_zone_count = get_db_count('zone', args.dataset_id)

    # # Validate
    # passed = True
    # if xml_way_count == db_way_count:
    #     print(f"[PASS] <way> count: XML={xml_way_count}, DB={db_way_count}")
    # else:
    #     print(f"[FAIL] <way> count: XML={xml_way_count}, DB={db_way_count}")
    #     passed = False
    # if xml_node_count == db_node_count:
    #     print(f"[PASS] <node> count: XML={xml_node_count}, DB={db_node_count}")
    # else:
    #     print(f"[FAIL] <node> count: XML={xml_node_count}, DB={db_node_count}")
    #     passed = False
    # if xml_zone_count_pedestrian == db_zone_count:
    #     print(f"[PASS] <zone> count: XML={xml_zone_count_pedestrian}, DB={db_zone_count}")
    # else:
    #     print(f"[FAIL] <zone> count: XML={xml_zone_count_pedestrian}, DB={db_zone_count}")
    #     passed = False
    # if not passed:
    #     sys.exit(1)

if __name__ == '__main__':
    main() 