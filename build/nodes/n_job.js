// Status job: which machines are inside a scheduled window right now (maintenance or cleaning)
// Clock: PLANT_CLOCK env var (tests / demo, e.g. 2026-10-19T08:30) or the current time.

const fs = require('fs');
const schedules = JSON.parse(fs.readFileSync('/data/maintenance_schedule.json', 'utf8')).schedules || [];
const DAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

let day, hour;
const m = ($env.PLANT_CLOCK || '').match(/(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})/);
if (m) { day = DAYS[new Date(Date.UTC(+m[1], +m[2] - 1, +m[3])).getUTCDay()]; hour = +m[4] + +m[5] / 60; }
else { day = $now.weekdayLong; hour = $now.hour + $now.minute / 60; }

const active = schedules.filter(s => {
  const [h, mi] = (s.time || '00:00').split(':').map(Number);
  const start = h + mi / 60;
  return (!s.day_of_week || s.day_of_week === day) && hour >= start && hour < start + (s.duration_hours || 1);
});

return [{ json: {
  clock: `${day} ${String(Math.floor(hour)).padStart(2, '0')}:${String(Math.round((hour % 1) * 60)).padStart(2, '0')}`,
  active_ids: `{${[...new Set(active.map(s => s.equipment_id))].join(',')}}`,   // Postgres text[] literal
  active: active.map(s => `${s.equipment_id} ${s.schedule_type} (${s.method})`)
} }];
