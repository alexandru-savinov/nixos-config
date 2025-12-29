#!/usr/bin/env python3
"""
Open WebUI Pipe Function Provisioning Script
Automatically provisions the OpenRouter ZDR-Only Models pipe function
"""

import hashlib
import json
import logging
import os
import sqlite3
import sys
import time
from pathlib import Path
from typing import Optional

# Configure logging
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)


class PipeFunctionProvisioner:
    def __init__(self, db_path: str, function_file: str):
        self.db_path = Path(db_path)
        self.function_file = Path(function_file)
        self.conn = None

    def __enter__(self):
        """Context manager entry."""
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        """Context manager exit - cleanup connections."""
        if self.conn:
            self.conn.close()

    def _get_function_content(self) -> str:
        """Read the pipe function Python code."""
        try:
            with open(self.function_file, "r", encoding="utf-8") as f:
                return f.read()
        except FileNotFoundError:
            logger.error(f"Function file not found: {self.function_file}")
            raise
        except Exception as e:
            logger.error(f"Error reading function file: {e}")
            raise

    def _calculate_hash(self, content: str) -> str:
        """Calculate SHA256 hash of function content."""
        return hashlib.sha256(content.encode("utf-8")).hexdigest()

    def _get_function_metadata(self, content: str) -> dict:
        """Extract metadata from function docstring."""
        metadata = {
            "name": "OpenRouter ZDR-Only Models",
            "description": "Only shows OpenRouter models with Zero Data Retention policy",
            "type": "pipe",
            "meta": {
                "title": "OpenRouter ZDR-Only Models",
                "author": "nixos-config",
                "version": "0.1.0",
                "description": "Only shows OpenRouter models with Zero Data Retention policy",
            },
        }

        # Try to extract metadata from docstring
        lines = content.split("\n")
        in_docstring = False
        docstring_lines = []

        for line in lines:
            if line.strip().startswith('"""'):
                if in_docstring:
                    break
                in_docstring = True
                continue
            if in_docstring:
                docstring_lines.append(line.strip())

        # Parse key-value pairs from docstring
        for line in docstring_lines:
            if ":" in line:
                key, value = line.split(":", 1)
                key = key.strip().lower()
                value = value.strip()

                if key == "title":
                    metadata["name"] = value
                    metadata["meta"]["title"] = value
                elif key == "author":
                    metadata["meta"]["author"] = value
                elif key == "version":
                    metadata["meta"]["version"] = value
                elif key == "description":
                    metadata["description"] = value
                    metadata["meta"]["description"] = value

        return metadata

    def _connect_db(self) -> bool:
        """Connect to SQLite database."""
        try:
            self.conn = sqlite3.connect(str(self.db_path))
            self.conn.row_factory = sqlite3.Row
            logger.info(f"Connected to database: {self.db_path}")
            return True
        except sqlite3.Error as e:
            logger.error(f"Database connection error: {e}")
            return False

    def _function_exists(self, name: str) -> bool:
        """Check if function already exists in database."""
        try:
            cursor = self.conn.cursor()
            cursor.execute("SELECT COUNT(*) FROM function WHERE name = ?", (name,))
            count = cursor.fetchone()[0]
            return count > 0
        except sqlite3.Error as e:
            logger.error(f"Error checking function existence: {e}")
            return False

    def _get_existing_function_hash(self, name: str) -> Optional[str]:
        """Get hash of existing function content."""
        try:
            cursor = self.conn.cursor()
            cursor.execute("SELECT content FROM function WHERE name = ?", (name,))
            row = cursor.fetchone()
            if row:
                return self._calculate_hash(row["content"])
            return None
        except sqlite3.Error as e:
            logger.error(f"Error getting existing function hash: {e}")
            return None

    def _insert_function(self, name: str, content: str, metadata: dict) -> bool:
        """Insert new function into database."""
        try:
            cursor = self.conn.cursor()

            # Prepare function data
            function_data = {
                "name": name,
                "content": content,
                "type": metadata["type"],
                "description": metadata["description"],
                "is_active": True,
                "is_global": True,
                "meta": json.dumps(metadata["meta"]),
                "user_id": None,  # Global function
                "updated_at": int(time.time()),
            }

            # Insert function
            columns = ", ".join(function_data.keys())
            placeholders = ", ".join(["?" for _ in function_data])

            cursor.execute(
                f"INSERT INTO function ({columns}) VALUES ({placeholders})",
                tuple(function_data.values()),
            )

            self.conn.commit()
            logger.info(f"Inserted new function: {name}")
            return True

        except sqlite3.Error as e:
            logger.error(f"Error inserting function: {e}")
            self.conn.rollback()
            return False

    def _update_function(self, name: str, content: str, metadata: dict) -> bool:
        """Update existing function in database."""
        try:
            cursor = self.conn.cursor()

            # Prepare update data
            update_data = {
                "content": content,
                "type": metadata["type"],
                "description": metadata["description"],
                "is_active": True,
                "is_global": True,
                "meta": json.dumps(metadata["meta"]),
                "updated_at": int(time.time()),
            }

            # Update function
            set_clause = ", ".join([f"{k} = ?" for k in update_data.keys()])

            cursor.execute(
                f"UPDATE function SET {set_clause} WHERE name = ?",
                (*update_data.values(), name),
            )

            self.conn.commit()
            logger.info(f"Updated function: {name}")
            return True

        except sqlite3.Error as e:
            logger.error(f"Error updating function: {e}")
            self.conn.rollback()
            return False

    def provision_function(self) -> bool:
        """Provision the pipe function."""
        try:
            # Read function content
            content = self._get_function_content()
            current_hash = self._calculate_hash(content)

            # Get function metadata
            metadata = self._get_function_metadata(content)
            function_name = metadata["name"]

            logger.info(f"Provisioning function: {function_name}")

            # Connect to database
            if not self._connect_db():
                return False

            # Check if function exists
            if self._function_exists(function_name):
                # Check if content has changed
                existing_hash = self._get_existing_function_hash(function_name)

                if existing_hash == current_hash:
                    logger.info(f"Function {function_name} is up to date")
                    return True
                else:
                    logger.info(f"Function {function_name} has changed, updating...")
                    return self._update_function(function_name, content, metadata)
            else:
                logger.info(f"Function {function_name} does not exist, creating...")
                return self._insert_function(function_name, content, metadata)

        except Exception as e:
            logger.error(f"Error provisioning function: {e}")
            return False


def main():
    """Main entry point."""
    if len(sys.argv) != 3:
        print("Usage: provision.py <database_path> <function_file>")
        sys.exit(1)

    db_path = sys.argv[1]
    function_file = sys.argv[2]

    # Validate inputs
    if not os.path.exists(function_file):
        logger.error(f"Function file does not exist: {function_file}")
        sys.exit(1)

    # Wait for database to be available
    max_retries = 30
    retry_delay = 1

    for attempt in range(max_retries):
        if os.path.exists(db_path):
            break
        logger.info(f"Waiting for database... (attempt {attempt + 1}/{max_retries})")
        time.sleep(retry_delay)
    else:
        logger.error(f"Database not found after {max_retries} attempts: {db_path}")
        sys.exit(1)

    # Provision function
    with PipeFunctionProvisioner(db_path, function_file) as provisioner:
        success = provisioner.provision_function()

        if success:
            logger.info("Function provisioning completed successfully")
            sys.exit(0)
        else:
            logger.error("Function provisioning failed")
            sys.exit(1)


if __name__ == "__main__":
    main()
