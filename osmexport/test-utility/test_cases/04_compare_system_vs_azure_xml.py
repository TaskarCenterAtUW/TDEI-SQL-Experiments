import sys
import argparse
import psycopg2
import os
import difflib
from azure.storage.blob import BlobClient
from urllib.parse import urlparse
import re
from dotenv import load_dotenv

# Load environment variables from .env file
load_dotenv()

# --- CONFIGURE THESE ---
DB_CONFIG = {
    'host': os.environ.get('DB_HOST'),
    'port': int(os.environ.get('DB_PORT', 5432)),
    'dbname': os.environ.get('DB_NAME'),
    'user': os.environ.get('DB_USER'),
    'password': os.environ.get('DB_PASSWORD')
}

AZURE_CONFIG = {
    'container': os.environ.get('AZURE_CONTAINER'),
    'connection_string': os.environ.get('AZURE_CONNECTION_STRING')
}

def get_latest_osm_url(dataset_id):
    sql = "SELECT latest_osm_url FROM content.dataset WHERE tdei_dataset_id = %s"
    try:
        conn = psycopg2.connect(**DB_CONFIG)
        cur = conn.cursor()
        cur.execute(sql, (dataset_id,))
        result = cur.fetchone()
        cur.close()
        conn.close()
        if not result or not result[0]:
            print(f"[FAIL] No latest_osm_url found for dataset {dataset_id}")
            sys.exit(1)
        return result[0]
    except Exception as e:
        print(f"[FAIL] DB error: {e}")
        sys.exit(1)

def get_blob_name_from_url(blob_url, container_name):
    parsed = urlparse(blob_url)
    path = parsed.path.lstrip('/')
    if path.startswith(container_name + '/'):  # Remove container name
        blob_name = path[len(container_name) + 1:]
    else:
        blob_name = path
    return blob_name

def download_azure_blob(blob_url, container_name, connection_string):
    blob_name = get_blob_name_from_url(blob_url, container_name)
    try:
        blob_client = BlobClient.from_connection_string(
            conn_str=connection_string,
            container_name=container_name,
            blob_name=blob_name
        )
        blob_data = blob_client.download_blob().readall()
        return blob_data.decode('utf-8')
    except Exception as e:
        print(f"[FAIL] Azure download error: {e}")
        sys.exit(1)

def normalize_xml(xml):
    # Remove node and way IDs and <nd ref=...> values
    xml = re.sub(r'(id=")[^"]*"', 'id=""', xml)
    xml = re.sub(r'<nd ref="[^"]*"\s*/>', '<nd ref=""/>', xml)

    def sort_tags_in_block(block):
        # Find all <tag .../> elements
        tags = re.findall(r'<tag[^>]*/>', block)
        # Remove tags where k ends with '_id'
        tags = [tag for tag in tags if not re.search(r'k="[^"]*_id"', tag)]
        # Sort tags by k attribute
        def get_k(tag):
            m = re.search(r'k="([^"]*)"', tag)
            return m.group(1) if m else ''
        tags_sorted = sorted(tags, key=get_k)
        # Remove all tags from block
        block_wo_tags = re.sub(r'<tag[^>]*/>\s*', '', block)
        # If this is a <node>...</node> block and no tags remain, convert to self-closing <node .../>
        if block.strip().startswith('<node'):
            # Remove tags and check if only attributes remain
            # Get the opening <node ...> tag
            m = re.match(r'<node([^>]*)>', block)
            if m and not tags_sorted:
                attrs = m.group(1).strip()
                # Compose self-closing node
                return f'<node{(" " + attrs) if attrs else ""}/>'
        # Insert sorted tags before closing tag
        block_wo_tags = re.sub(r'(</(node|way)>)', lambda m: ''.join(tags_sorted) + m.group(1), block_wo_tags)
        return block_wo_tags

    # Sort tags in <node>...</node> blocks
    xml = re.sub(r'<node[\s\S]*?</node>', lambda m: sort_tags_in_block(m.group(0)), xml)
    # Sort tags in <way[\s\S]*?</way> blocks
    xml = re.sub(r'<way[\s\S]*?</way>', lambda m: sort_tags_in_block(m.group(0)), xml)

    # Collapse each <way ...>...</way> block to a single line
    # def way_to_single_line(match):
    #     return match.group(0).replace('\n', '').replace('\r', '').replace('  ', ' ')
    # xml = re.sub(r'<way[\s\S]*?</way>', lambda m: way_to_single_line(m), xml)
    # # Collapse each <tag .../> to a single line (remove newlines/extra spaces inside tag)
    # def tag_to_single_line(match):
    #     return match.group(0).replace('\n', '').replace('\r', '').replace('  ', ' ')
    # xml = re.sub(r'<tag[^>]*/>', lambda m: tag_to_single_line(m), xml)
    return xml

def extract_elements(xml, tag):
    # Extract all <tag .../> or <tag ...>...</tag> as single lines
    # For <node .../>
    if tag == 'node':
        return set(re.findall(r'<node[^>]*/>', xml))
    # For <way ...>...</way>
    elif tag == 'way':
        return set(re.findall(r'<way[\s\S]*?</way>', xml))
    return set()

def main():
    parser = argparse.ArgumentParser(description='Compare system-generated XML with Azure-stored XML for a dataset.')
    parser.add_argument('dataset_id', help='Dataset ID to check')
    parser.add_argument('xml_file', nargs='?', help='Path to system-generated XML output file (optional if --stdin is used)')
    parser.add_argument('--stdin', action='store_true', help='Read system-generated XML from stdin')
    parser.add_argument('--container', default=AZURE_CONFIG['container'], help='Azure Storage container name')
    parser.add_argument('--connection-string', default=AZURE_CONFIG['connection_string'], help='Azure Storage connection string')
    args = parser.parse_args()

    if not args.container or not args.connection_string:
        print('Azure Storage container and connection string must be provided (either in AZURE_CONFIG or via command line).')
        sys.exit(1)

    # Read system-generated XML
    if args.stdin:
        sys_xml = sys.stdin.read()
    elif args.xml_file:
        with open(args.xml_file, 'r', encoding='utf-8') as f:
            sys_xml = f.read()
    else:
        print('No system-generated XML input provided.')
        sys.exit(1)

    # Get Azure URL from DB
    azure_url = get_latest_osm_url(args.dataset_id)
    print(f"[INFO] Downloading Azure XML from: {azure_url}")
    azure_xml = download_azure_blob(azure_url, args.container, args.connection_string)

    # Store Azure XML under osm folder
    osm_dir = os.path.join(os.path.dirname(__file__), '../osm')
    os.makedirs(osm_dir, exist_ok=True)
    azure_xml_path = os.path.join(osm_dir, f"{args.dataset_id}_azure.xml")
    with open(azure_xml_path, 'w', encoding='utf-8') as f:
        f.write(azure_xml)
    print(f"[INFO] Azure XML saved to: {azure_xml_path}")

    # Compare (normalized)
    sys_xml_norm = normalize_xml(sys_xml.strip())
    # with open("sys_xml_normalized.xml", "w", encoding="utf-8") as f:
    #     f.write(sys_xml_norm)
    azure_xml_norm = normalize_xml(azure_xml.strip())

    # Compare as sets of nodes and ways
    sys_nodes = extract_elements(sys_xml_norm, 'node')
    azure_nodes = extract_elements(azure_xml_norm, 'node')
    sys_ways = extract_elements(sys_xml_norm, 'way')
    azure_ways = extract_elements(azure_xml_norm, 'way')

    missing_nodes = azure_nodes - sys_nodes
    extra_nodes = sys_nodes - azure_nodes
    missing_ways = azure_ways - sys_ways
    extra_ways = sys_ways - azure_ways

    if not missing_nodes and not extra_nodes and not missing_ways and not extra_ways:
        print('[PASS] System-generated XML matches Azure-stored XML (nodes and ways, ignoring order and IDs/refs).')
    else:
        print('[FAIL] System-generated XML does NOT match Azure-stored XML (nodes and ways, ignoring order and IDs/refs).')
        if missing_nodes:
            print(f'Missing nodes ({len(missing_nodes)}), showing top 3:')
            for n in sorted(missing_nodes)[:3]:
                print(n)
        if extra_nodes:
            print(f'Extra nodes ({len(extra_nodes)}), showing top 3:')
            for n in sorted(extra_nodes)[:3]:
                print(n)
        if missing_ways:
            print(f'Missing ways ({len(missing_ways)}), showing top 3:')
            for w in sorted(missing_ways)[:3]:
                print(w)
        if extra_ways:
            print(f'Extra ways ({len(extra_ways)}), showing top 3:')
            for w in sorted(extra_ways)[:3]:
                print(w)
        sys.exit(1)

if __name__ == '__main__':
    main() 