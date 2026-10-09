import re

with open('lib/features/home/presentation/widgets/home_cards.dart', 'r') as f:
    content = f.read()

# Replace const SizedBox
content = re.sub(r'const\s+SizedBox', r'SizedBox', content)
# Replace const EdgeInsets
content = re.sub(r'const\s+EdgeInsets', r'EdgeInsets', content)
# Replace const BorderRadius
content = re.sub(r'const\s+BorderRadius', r'BorderRadius', content)
# Replace const Icon
content = re.sub(r'const\s+Icon', r'Icon', content)

with open('lib/features/home/presentation/widgets/home_cards.dart', 'w') as f:
    f.write(content)

