import logging
from pathlib import Path

import psycopg

from .config import load_settings

log = logging.getLogger("migrate")


def run(dsn, directory):
    with psycopg.connect(dsn, autocommit=True) as conn:
        conn.execute("CREATE TABLE IF NOT EXISTS schema_migrations (version TEXT PRIMARY KEY)")
        applied = {row[0] for row in conn.execute("SELECT version FROM schema_migrations")}
        for path in sorted(Path(directory).glob("*.sql")):
            if path.name in applied:
                continue
            with conn.transaction():
                conn.execute(path.read_text())
                conn.execute("INSERT INTO schema_migrations (version) VALUES (%s)", (path.name,))
            log.info("applied %s", path.name)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    run(load_settings().dsn, "migrations")
