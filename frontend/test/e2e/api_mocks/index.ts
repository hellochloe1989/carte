import { createRequire } from 'node:module'

const requireFn = createRequire(import.meta.url)

export const API_STATUS = requireFn('./api_mock_status.json')

export const API_BOOTSTRAP_FG = requireFn('./api_mock_bootstrap_fg.json')
export const API_BOOTSTRAP_CEC = requireFn('./api_mock_bootstrap_cec.json')
