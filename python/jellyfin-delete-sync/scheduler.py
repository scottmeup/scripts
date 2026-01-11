# scheduler.py
from apscheduler.schedulers.background import BackgroundScheduler
from apscheduler.triggers.cron import CronTrigger
from apscheduler.triggers.interval import IntervalTrigger
from sonarr import build_provider_map
from utils import log
from config import REFRESH_INTERVAL_MINUTES, REFRESH_SCHEDULE

def setup_scheduler():
    scheduler = BackgroundScheduler()
    scheduler.start()

    has_refresh = False

    if REFRESH_INTERVAL_MINUTES is not None:
        log(f"Configured interval refresh every {REFRESH_INTERVAL_MINUTES} minutes")
        scheduler.add_job(build_provider_map, IntervalTrigger(minutes=REFRESH_INTERVAL_MINUTES), id='interval_refresh', replace_existing=True)
        has_refresh = True

    if REFRESH_SCHEDULE is not None:
        log(f"Configured {len(REFRESH_SCHEDULE)} scheduled refresh time(s)")
        for i, sched in enumerate(REFRESH_SCHEDULE):
            day = sched.get('day', '*').lower()
            hour = sched.get('hour', 3)
            minute = sched.get('minute', 0)
            scheduler.add_job(build_provider_map, CronTrigger(day_of_week=day, hour=hour, minute=minute),
                              id=f'scheduled_refresh_{i}', replace_existing=True)
            log(f"  - {day.title() if day != '*' else 'Every day'} at {hour:02d}:{minute:02d}")
        has_refresh = True

    if not has_refresh:
        log("No automatic refresh configured")

    return scheduler