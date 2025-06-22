# Service A with Redis persistence for pod restart resilience
import requests
import time
import logging
import json
import redis
from datetime import datetime, timedelta
from collections import deque
import os
import threading
from flask import Flask, jsonify

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(message)s')
logger = logging.getLogger(__name__)

# Flask app
app = Flask(__name__)

class BitcoinPriceMonitor:
    def __init__(self):
        # Redis connection
        self.redis_host = os.getenv('REDIS_HOST', 'redis-service')
        self.redis_port = int(os.getenv('REDIS_PORT', '6379'))
        self.redis_client = None
        self._connect_redis()
        
        # Multiple APIs for fallback resilience
        self.apis = [
            {
                "name": "CoinGecko",
                "url": "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd",
                "parser": self._parse_coingecko
            },
            {
                "name": "CoinDesk", 
                "url": "https://api.coindesk.com/v1/bpi/currentprice/USD.json",
                "parser": self._parse_coindesk
            },
            {
                "name": "Binance",
                "url": "https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT",
                "parser": self._parse_binance
            }
        ]
        
        # In-memory cache (for performance)
        self.prices = deque(maxlen=10)
        self.current_price = None
        self.last_updated = None
        self.current_source = None
        
        # NEW: 10-minute average caching
        self.cached_average = 0
        self.last_average_calculation = None
        
        # Load existing data from Redis on startup
        self._load_from_redis()
        
    def _connect_redis(self):
        """Connect to Redis with retry logic"""
        max_retries = 5
        for attempt in range(max_retries):
            try:
                self.redis_client = redis.Redis(
                    host=self.redis_host, 
                    port=self.redis_port, 
                    decode_responses=True,
                    socket_connect_timeout=5,
                    socket_timeout=5
                )
                # Test connection
                self.redis_client.ping()
                logger.info(f"✅ Connected to Redis at {self.redis_host}:{self.redis_port}")
                return
            except Exception as e:
                logger.warning(f"❌ Redis connection attempt {attempt + 1} failed: {e}")
                if attempt < max_retries - 1:
                    time.sleep(2 ** attempt)  # Exponential backoff
                
        logger.error("🚨 Failed to connect to Redis after all retries")
        self.redis_client = None
        
    def _save_to_redis(self, price, source):
        """Save price data to Redis with timestamp"""
        if not self.redis_client:
            return
            
        try:
            timestamp = datetime.now().isoformat()
            price_data = {
                "price": price,
                "source": source,
                "timestamp": timestamp
            }
            
            # Save current price
            self.redis_client.set("bitcoin:current", json.dumps(price_data))
            
            # Add to price history (sorted set with timestamp as score)
            score = time.time()  # Unix timestamp for sorting
            self.redis_client.zadd("bitcoin:history", {json.dumps(price_data): score})
            
            # Keep only last 10 minutes of data (600 seconds)
            cutoff_time = time.time() - 600
            self.redis_client.zremrangebyscore("bitcoin:history", 0, cutoff_time)
            
            logger.debug(f"💾 Saved to Redis: ${price:,.2f} from {source}")
            
        except Exception as e:
            logger.error(f"❌ Failed to save to Redis: {e}")
            
    def _load_from_redis(self):
        """Load existing price data from Redis on startup"""
        if not self.redis_client:
            logger.warning("⚠️ No Redis connection - starting fresh")
            return
            
        try:
            # Load current price
            current_data = self.redis_client.get("bitcoin:current")
            if current_data:
                data = json.loads(current_data)
                self.current_price = data["price"]
                self.current_source = data["source"]
                self.last_updated = data["timestamp"]
                logger.info(f"🔄 Restored current price from Redis: ${self.current_price:,.2f}")
            
            # Load price history (last 10 minutes)
            cutoff_time = time.time() - 600
            history_data = self.redis_client.zrangebyscore("bitcoin:history", cutoff_time, "+inf")
            
            for item in history_data:
                data = json.loads(item)
                self.prices.append(data["price"])
                
            logger.info(f"🔄 Restored {len(self.prices)} price points from Redis")
            
        except Exception as e:
            logger.error(f"❌ Failed to load from Redis: {e}")
            
    def _get_redis_average(self):
        """Get 10-minute average directly from Redis (fallback when pods restart)"""
        if not self.redis_client:
            return None
            
        try:
            cutoff_time = time.time() - 600  # Last 10 minutes
            history_data = self.redis_client.zrangebyscore("bitcoin:history", cutoff_time, "+inf")
            
            if not history_data:
                return None
                
            prices = []
            for item in history_data:
                data = json.loads(item)
                prices.append(data["price"])
                
            return sum(prices) / len(prices) if prices else None
            
        except Exception as e:
            logger.error(f"❌ Failed to get Redis average: {e}")
            return None
        
    def _parse_coingecko(self, response):
        """Parse CoinGecko API response"""
        data = response.json()
        return float(data['bitcoin']['usd'])
        
    def _parse_coindesk(self, response):
        """Parse CoinDesk API response"""
        data = response.json()
        price_str = data['bpi']['USD']['rate'].replace(',', '').replace('$', '')
        return float(price_str)
        
    def _parse_binance(self, response):
        """Parse Binance API response"""
        data = response.json()
        return float(data['price'])
        
    def get_bitcoin_price(self):
        """Try multiple APIs in order until one succeeds"""
        for api in self.apis:
            try:
                logger.info(f"Trying {api['name']} API...")
                response = requests.get(api['url'], timeout=10)
                response.raise_for_status()
                
                price = api['parser'](response)
                logger.info(f"✅ Successfully fetched price from {api['name']}: ${price:,.2f}")
                return price, api['name']
                
            except Exception as e:
                logger.warning(f"❌ {api['name']}: {e}")
                continue
        
        logger.error("🚨 All Bitcoin APIs failed!")
        return None, None
    
    def _should_recalculate_average(self):
        """Check if 10 minutes have passed since last average calculation"""
        if self.last_average_calculation is None:
            return True
        
        elapsed = datetime.now() - self.last_average_calculation
        return elapsed >= timedelta(minutes=10)
    
    def calculate_average(self):
        """Calculate average only every 10 minutes, otherwise return cached value"""
        # Return cached average if less than 10 minutes have passed
        if not self._should_recalculate_average():
            return self.cached_average
        
        # Calculate new average (same logic as before)
        if len(self.prices) > 0:
            new_average = sum(self.prices) / len(self.prices)
        else:
            # Fallback to Redis (for when pod just restarted)
            redis_avg = self._get_redis_average()
            new_average = redis_avg if redis_avg else 0
        
        # Update cache
        self.cached_average = new_average
        self.last_average_calculation = datetime.now()
        
        logger.info(f"📈 NEW Average calculated: ${new_average:,.2f} USD (will be used for next 10 minutes)")
        return new_average
    
    def run_monitor(self):
        """Background monitoring function"""
        logger.info("Bitcoin Price Monitor started with Redis persistence")
        minute_counter = 0
        
        while True:
            price, source = self.get_bitcoin_price()
            
            if price is not None:
                # Update in-memory data
                self.prices.append(price)
                self.current_price = price
                self.current_source = source
                self.last_updated = datetime.now().isoformat()
                minute_counter += 1
                
                # Persist to Redis
                self._save_to_redis(price, source)
                
                logger.info(f"📊 Bitcoin Price: ${price:,.2f} USD (from {source})")
                
                # CHANGED: Only log average every 10 minutes (when it actually updates)
                if minute_counter % 10 == 0:
                    avg_price = self.calculate_average()  # This will trigger recalculation
                    logger.info(f"🔄 Updated 10-minute average: ${avg_price:,.2f} USD")
            else:
                logger.warning("⚠️ Failed to fetch price from any API, will retry in 60 seconds")
            
            time.sleep(60)

# Create global monitor instance
monitor = BitcoinPriceMonitor()

@app.route('/service-a')
def get_current_price():
    """Get current Bitcoin price - ONLY endpoint"""
    if monitor.current_price is None:
        return jsonify({
            "error": "Price not available yet",
            "service": "bitcoin-service-a",
            "status": "No successful API calls yet"
        }), 503
    
    # Base response (always included)
    response = {
        "service": "bitcoin-service-a",
        "current_price": f"${monitor.current_price:,.2f} USD",
        "last_updated": monitor.last_updated,
        "price_history_count": len(monitor.prices),
        "data_source": monitor.current_source,
        "persistence": "Redis-backed"
    }
    
    # ONLY include average_10min field if we're at a 10-minute mark
    if monitor._should_recalculate_average():
        avg_price = monitor.calculate_average()  # This will trigger recalculation
        response["average_10min"] = f"${avg_price:,.2f} USD" if avg_price > 0 else "Not enough data"
    
    return jsonify(response)

@app.route('/health')
def health_check():
    """Health check for Kubernetes probes"""
    redis_status = "connected" if monitor.redis_client else "disconnected"
    
    return jsonify({
        "status": "healthy" if monitor.current_price is not None else "unhealthy",
        "service": "bitcoin-service-a", 
        "has_price_data": monitor.current_price is not None,
        "last_successful_source": monitor.current_source,
        "redis_status": redis_status
    })

if __name__ == "__main__":
    # Start background monitoring
    monitor_thread = threading.Thread(target=monitor.run_monitor, daemon=True)
    monitor_thread.start()
    
    logger.info("Starting Flask web server with Redis persistence")
    app.run(host='0.0.0.0', port=8080, debug=False)