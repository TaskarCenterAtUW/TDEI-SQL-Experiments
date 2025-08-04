import json

# def count_geojson_features(filepath):
#     with open(filepath, 'r', encoding='utf-8') as f:
#         data = json.load(f)
#     # GeoJSON FeatureCollection has a "features" key
#     if 'features' in data:
#         return len(data['features'])
#     else:
#         raise ValueError("Invalid GeoJSON: No 'features' key found.")

# # Example usage:
# num_features = count_geojson_features('snohomish.edges.geojson')
# print(f"Number of features: {num_features}")

import xml.etree.ElementTree as ET

def count_way_tags(xml_file):
    tree = ET.parse(xml_file)
    root = tree.getroot()
    # Find all 'way' elements in the XML
    way_tags = root.findall('.//node')
    return len(way_tags)

# Example usage:
num_ways = count_way_tags('osmexport/test-utility/osm/TDEI_OSM_Snohamish.xml')
print(f"Number of <node> tags: {num_ways}")