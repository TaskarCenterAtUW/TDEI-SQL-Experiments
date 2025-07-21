import sys
import argparse
import re
import xml.etree.ElementTree as ET
from lxml import etree

def clean_tag_attribute_quotes(xml):
    # Replace double quotes and ampersands in k="..." and v="..." attribute values
    def repl_attr(m):
        attr = m.group(1)  # k= or v=
        val = m.group(2)
        #val = val.replace('"', '').replace('"', '')
        if "Bicycles" in val:
            print(f'{attr}"{val}"')
        return f'{attr}"{val}"'
    xml = re.sub(r'(k=|v=)"([^"]*)"', repl_attr, xml)
    return xml

def check_xml_validity(xml):
    try:
        xml = clean_tag_attribute_quotes(xml)
        ET.fromstring(xml)
        # parser = etree.XMLParser(recover=True)
        # root = etree.fromstring(xml, parser=parser)
        return True, None
    except ET.ParseError as e:
        return False, f'! XML ParseError: {e}'

def check_unwanted_characters(xml):
    # Allow only printable chars, tabs, newlines, carriage returns
    # Disallow ASCII control chars except \t, \n, \r
    unwanted = re.findall(r'[\x00-\x08\x0b\x0c\x0e-\x1f]', xml)
    if unwanted:
        return False, f'Unwanted control characters found: {set(unwanted)}'
    return True, None

def check_pedestrian_area_logic(xml):
    xml = clean_tag_attribute_quotes(xml)
    xml = xml.replace("&", "")
    root = ET.fromstring(xml)
    # root = xml
    failed = False
    # Collect all way ids referenced in relations
    referenced_way_ids = set()
    for rel in root.iter('relation'):
        for member in rel.findall('member'):
            if member.attrib.get('type') == 'way':
                ref = member.attrib.get('ref')
                if ref is not None:
                    referenced_way_ids.add(ref)
    # Test 1: For each way with highway=pedestrian, if id not in referenced_way_ids, must have area=yes
    for way in root.iter('way'):
        way_id = way.attrib.get('id', '')
        tags = {tag.attrib.get('k'): tag.attrib.get('v') for tag in way.iter('tag')}
       
        if tags.get('highway') == 'pedestrian' and tags.get('surface') == 'paving_stones' and way_id not in referenced_way_ids:
            if tags.get('area') != 'yes':
                print(f"[FAIL] <way id='{way_id}'> with highway=pedestrian not in any relation is missing area=yes")
                failed = True
    # Test 2: For each relation with highway=pedestrian and type=multipolygon, must have area=yes
    for rel in root.iter('relation'):
        tags = {tag.attrib.get('k'): tag.attrib.get('v') for tag in rel.iter('tag')}
        
        if tags.get('highway') == 'pedestrian' and tags.get('type') == 'multipolygon':
            if tags.get('area') != 'yes':
                print(f"[FAIL] <relation> with highway=pedestrian and type=multipolygon is missing area=yes")
                failed = True
    if not failed:
        print('[PASS] Pedestrian area logic for ways and relations is correct.')
    else:
        sys.exit(1)

def check_forbidden_tag_keys(xml):
    xml = clean_tag_attribute_quotes(xml)
    xml = xml.replace("&", "")
    root = ET.fromstring(xml)
    # root = xml
    forbidden_keys = {'_v_id', '_u_id', '_w_id', 'length'}
    failed = False
    for elem in list(root.iter('way')) + list(root.iter('relation')):
        for tag in elem.iter('tag'):
            k = tag.attrib.get('k')
            if k in forbidden_keys:
                print(f"[FAIL] <{elem.tag}> with forbidden tag key: {k}")
                failed = True
    if not failed:
        print('[PASS] No forbidden tag keys (_v_id, _u_id, _w_id, length) found in ways or relations.')
    else:
        sys.exit(1)

def main():
    parser = argparse.ArgumentParser(description='Check XML syntax validity and unwanted characters.')
    parser.add_argument('dataset_id', help='Dataset ID (not used, for interface consistency)')
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

    # Check XML validity
    valid, reason = check_xml_validity(xml)
    if valid:
        print('[PASS] XML is well-formed.')
    else:
        print(f'[FAIL] {reason}')
        sys.exit(1)

    # Check for unwanted characters
    clean, reason = check_unwanted_characters(xml)
    if clean:
        print('[PASS] No unwanted control characters in XML.')
    else:
        print(f'[FAIL] {reason}')
        sys.exit(1)

    # New test for pedestrian area and tag transformation
    check_pedestrian_area_logic(xml)

    # New test for forbidden tag keys
    check_forbidden_tag_keys(xml)

if __name__ == '__main__':
    main() 