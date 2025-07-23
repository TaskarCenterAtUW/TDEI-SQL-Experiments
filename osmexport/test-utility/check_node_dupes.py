import xml.etree.ElementTree as ET
import sys

def find_duplicate_nodes(xml_file):
    tree = ET.parse(xml_file)
    root = tree.getroot()
    seen = set()
    duplicates = []

    for node in root.iter('node'):
        lat = node.attrib.get('lat')
        lon = node.attrib.get('lon')
        key = (lat, lon)
        if key in seen:
            duplicates.append(node.attrib.get('id'))
        else:
            seen.add(key)

    if duplicates:
        print(f"Duplicate nodes found with same lat/lon: {duplicates}")
    else:
        print("No duplicate nodes with same lat/lon found.")

if __name__ == '__main__':
    if len(sys.argv) != 2:
        print("Usage: python check_duplicate_nodes.py <osm_xml_file>")
        sys.exit(1)
    find_duplicate_nodes(sys.argv[1])