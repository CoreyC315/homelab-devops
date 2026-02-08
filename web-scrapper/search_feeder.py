import redis
from playwright.sync_api import sync_playwright
import time

# Connect to your local mapped Redis
r = redis.Redis(host='localhost', port=6379, db=0)

def get_search_results(query):
    links = []
    with sync_playwright() as p:
        # CHANGED: headless=False so you can SEE what is happening
        browser = p.chromium.launch(headless=False)
        page = browser.new_page()
        
        print(f"Searching for: '{query}'...")
        
        page.goto("https://duckduckgo.com")
        
        # Type into the search box and hit Enter
        page.fill('input[name="q"]', query)
        page.press('input[name="q"]', "Enter")
        
        # CHANGED: Wait for the first actual result link to appear
        # This is more robust than waiting for a specific container class
        try:
            page.wait_for_selector('a[data-testid="result-title-a"]', timeout=10000)
        except Exception:
            print("Timed out waiting for results. The page structure might have changed.")
            browser.close()
            return []
        
        # Extract the result links
        results = page.query_selector_all('a[data-testid="result-title-a"]')
        
        print(f"Found {len(results)} results. Extracting top 10...")
        
        for i, result in enumerate(results):
            if i >= 10: break # Stop after 10
            url = result.get_attribute('href')
            if url:
                links.append(url)
                
        browser.close()
    return links

if __name__ == "__main__":
    topic = input("Enter a topic to scrape (e.g. 'kubernetes network policies'): ")
    
    urls = get_search_results(topic)
    
    if urls:
        print(f"\nPushing {len(urls)} URLs to the queue:")
        for url in urls:
            print(f" -> {url}")
            r.lpush("scrape_queue", url)
        print("\nDone! Watch your worker logs.")
    else:
        print("No URLs found. Checks your internet connection.")