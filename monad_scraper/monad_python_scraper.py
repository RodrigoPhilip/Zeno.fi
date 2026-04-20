import os
import requests
from bs4 import BeautifulSoup
from urllib.parse import urljoin

BASE_URL = "https://docs.monad.xyz"

def get_links(url):
    response = requests.get(url)
    soup = BeautifulSoup(response.content, 'html.parser')
    links = set()
    for a_tag in soup.find_all('a', href=True):
        href = a_tag['href']
        if href.startswith('/'):
            links.add(urljoin(BASE_URL, href))
        elif href.startswith(BASE_URL):
            links.add(href)
    return links

def extract_text(url):
    try:
        response = requests.get(url)
        soup = BeautifulSoup(response.content, 'html.parser')

        # Tentativa de pegar apenas o conteúdo principal (exclui sidebar, navbar, etc.)
        content = soup.find('main') or soup.find('article') or soup.find('body')
        if content:
            return content.get_text(separator='\n', strip=True)
    except Exception as e:
        print(f"Error extracting {url}: {e}")
    return ""

def main():
    print("Coletando links...")
    links = get_links(BASE_URL)
    print(f"Encontrados {len(links)} links iniciais.")

    # Busca mais um nivel
    all_links = set(links)
    for link in links:
        try:
            more_links = get_links(link)
            all_links.update(more_links)
        except Exception:
            continue

    print(f"Total de {len(all_links)} links coletados para scraping.")

    with open("monad_knowledge_base.txt", "w", encoding="utf-8") as f:
        f.write("# MONAD OFFICIAL DOCUMENTATION KNOWLEDGE BASE\n\n")

        for idx, link in enumerate(all_links):
            if not link.startswith(BASE_URL): continue

            print(f"[{idx+1}/{len(all_links)}] Scraping: {link}")
            text = extract_text(link)
            if text:
                f.write(f"\n--- SOURCE: {link} ---\n\n")
                f.write(text)
                f.write("\n\n")

if __name__ == "__main__":
    main()
