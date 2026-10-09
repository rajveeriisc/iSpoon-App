import re

with open('lib/features/home/presentation/widgets/home_cards.dart', 'r') as f:
    content = f.read()

# Replace fontSize
content = re.sub(r'fontSize:\s*(\d+\.?\d*)(?![\w\.])', r'fontSize: \1.sp', content)
# Replace width (but avoid width: double.infinity or width: constraints.maxWidth or width: x * y)
content = re.sub(r'width:\s*(\d+\.?\d*)(?![\w\.])', r'width: \1.w', content)
# Replace height
content = re.sub(r'height:\s*(\d+\.?\d*)(?![\w\.])', r'height: \1.h', content)
# Replace size (Icon size)
content = re.sub(r'size:\s*(\d+\.?\d*)(?![\w\.])', r'size: \1.sp', content)
# Replace circular()
content = re.sub(r'circular\(\s*(\d+\.?\d*)(?![\w\.])\)', r'circular(\1.r)', content)

# Write back
with open('lib/features/home/presentation/widgets/home_cards.dart', 'w') as f:
    f.write(content)

