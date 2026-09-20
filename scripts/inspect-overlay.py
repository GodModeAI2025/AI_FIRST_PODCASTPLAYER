#!/usr/bin/env python3
"""Read-only overlay inventory. Never modifies the target checkout."""
import argparse
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('checkout',type=Path);args=p.parse_args()
if not args.checkout.is_dir():p.error('Checkout directory does not exist')
root=Path(__file__).resolve().parents[1]
for src in sorted(root.rglob('*')):
 if src.is_file() and not any(x in src.parts for x in ['__pycache__','.git']):
  rel=src.relative_to(root);dst=args.checkout/rel
  state='CONFLICT/REVIEW' if dst.exists() else 'NEW/REVIEW'
  print(f'{state}\t{rel}')
print('DRY RUN ONLY: no files copied or overwritten.')
