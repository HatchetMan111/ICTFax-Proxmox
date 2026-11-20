import test from 'node:test'
import assert from 'node:assert/strict'
import { normalizePhone, safeMessage } from '../server/index.js'

test('normalizePhone keeps a leading plus and strips separators', () => {
  assert.equal(normalizePhone('+49 (30) 1234-5678'), '+493012345678')
  assert.equal(normalizePhone('030/123456'), '030123456')
  assert.equal(normalizePhone('0049 30 123456'), '+4930123456')
})

test('normalizePhone rejects too short, too long and non-string values', () => {
  assert.equal(normalizePhone('123'), '')
  assert.equal(normalizePhone('1'.repeat(21)), '')
  assert.equal(normalizePhone(null), '')
  assert.equal(normalizePhone(42), '')
})

test('safeMessage prefers structured upstream messages', () => {
  assert.equal(safeMessage({ message: 'boom' }, 'fallback'), 'boom')
  assert.equal(safeMessage({ error: { message: 'nested' } }, 'fallback'), 'nested')
  assert.equal(safeMessage('plain error', 'fallback'), 'plain error')
})

test('safeMessage falls back and truncates long strings', () => {
  assert.equal(safeMessage(null, 'fallback'), 'fallback')
  const long = 'x'.repeat(500)
  assert.equal(safeMessage(long, 'fallback').length, 300)
})
