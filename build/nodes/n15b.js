// Node 15b: Template response for escalations (no LLM call)
// Escalations are fully decided by Node 14, so a template is faster (~1 s saved) and cannot hallucinate.
// Output matches the Fireworks response shape so Node 17 handles both paths.

const v = $input.first().json;
let lines;

if (v.status === 'FALSE POSITIVE') {
  lines = [
    'Status: FALSE POSITIVE',
    `Diagnosis: ${v.sensor_type} ${v.sensor_value ?? ''} on ${v.equipment_id} is explained by context. ${v.explanation}`.replace(/\s+/g, ' ').trim(),
    `Action: No action needed.${v.recovery_time ? ` Readings should return to baseline by ${v.recovery_time}.` : ''}`,
    'Parts: None'
  ];
} else if (v.needs_clarification) {
  lines = [
    'Status: NEEDS INVESTIGATION',
    'Diagnosis: Report is too vague to diagnose: no equipment ID or sensor reading.',
    'Action: Specify the equipment ID and the sensor reading or symptom observed.',
    'Parts: None'
  ];
} else {
  lines = [
    'Status: NEEDS INVESTIGATION',
    `Diagnosis: ${v.reasons?.layer1 || 'Sensor evidence unclear'}. Evidence is not strong enough to confirm a fault (confidence ${v.confidence}%).`,
    `Action: Verify the sensor reading on ${v.equipment_id || 'the equipment'} and keep monitoring; escalate to a technician if it keeps rising.`,
    'Parts: None'
  ];
}

return [{ json: { source: 'template', choices: [{ message: { content: lines.join('\n') } }] } }];
