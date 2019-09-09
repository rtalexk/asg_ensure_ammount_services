const express = require('express');
const router = express.Router();
const fetch = require('node-fetch');

// Instance local link URL
const url = 'http://169.254.169.254/latest/meta-data';

/**
 * Catch response and error and wrap them into an array with [data, error]
 * @param { Promise } p
 */
const handle = p => p.then(async r => [await r.text()]).catch(e => [, e]);

/* GET home page. */
router.get('/', async (_, res) => {
  const failedToFetch = 'Failed to fetch';

  const [instance_id, instanceIdError] = await handle(fetch(`${url}/instance-id`));
  const [az, azError] = await handle(fetch(`${url}/placement/availability-zone`));

  if (instanceIdError || azError) {
    return res.render('index', { instance_id: failedToFetch, az: failedToFetch });
  }

  res.render('index', { instance_id, az });
});

router.get('/health', (_, res) => {
  res.send('Healthy');
});

module.exports = router;
