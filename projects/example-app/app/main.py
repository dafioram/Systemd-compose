import time
import sys
import os

print("App Started...")
port = os.getenv("PORT", "Unknown")

while True:
    print(f"Running on Port: {port}")
    sys.stdout.flush()
    time.sleep(10)