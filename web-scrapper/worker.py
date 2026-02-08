import os
import json
import redis
import time
from playwright.sync_api import sync_playwright
from bs4 import BeautifulSoup
import uuid

# Configuration
REDIS_HOST = os.getenv("REDIS_HOST", "redis-service")
QUEUE_NAME = "scrape_queue"
OUTPUT_DIR = "/mnt/data/raw_corpus" #make this map to the NAS

# Ensure the directory exists before we try to write to it
os.makedirs(OUTPUT_DIR, exist_ok=True)

r = redis.Redis(host=REDIS_HOST, port=6379, db=0)

def clean_text(html_content):
    soup = BeautifulSoup(html_content, "html.parser")
    # Remove script and style elements
    for script in soup(["script", "style", "nav", "footer", "header"]):
        script.extract()
    text = soup.get_text(separator=' ')
    # Collapse multiple spaces
    return " ".join(text.split())

def run():
    with sync_playwright() as p:
        # Launch browser (headless is default)
        browser = p.chromium.launch()
        
        print("Worker started. Waiting for URLs...")
        
        while True:
            # Blocking pop from Redis (waits until item is available)
            _, url_bytes = r.blpop(QUEUE_NAME)
            url = url_bytes.decode('utf-8')
            
            try:
                page = browser.new_page()
                page.goto(url, timeout=60000) # 60s timeout
                
                # Get content
                content = page.content()
                clean_body = clean_text(content)
                
                # Save as JSONL (Standard for LLM training)
                # We use a UUID filename to avoid write conflicts between pods
                data = {
                    "url": url,
                    "text": clean_body,
                    "timestamp": time.time()
                }
                
                filename = f"{OUTPUT_DIR}/{uuid.uuid4()}.json"
                with open(filename, "w") as f:
                    json.dump(data, f)
                    
                print(f"Scraped: {url}")
                page.close()
                
            except Exception as e:
                print(f"Failed {url}: {e}")
                # Optional: Push back to a 'failed_queue' here

if __name__ == "__main__":
    run()