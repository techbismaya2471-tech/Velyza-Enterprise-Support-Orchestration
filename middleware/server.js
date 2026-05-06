const express = require('express');
const axios = require('axios');
const cors = require('cors');

const app = express();

// CORS — preflight explicitly handle karo pehle
app.options('*', cors());
app.use(cors({
  origin: '*',
  methods: ['GET', 'POST', 'OPTIONS'],
  allowedHeaders: ['Content-Type', 'Authorization']
}));

app.use(express.json());

async function getSalesforceToken() {
  const response = await axios.post(
    `${process.env.SF_ORG_URL}/services/oauth2/token`,
    new URLSearchParams({
      grant_type: 'client_credentials',
      client_id: process.env.SF_CLIENT_ID,
      client_secret: process.env.SF_CLIENT_SECRET,
    })
  );
  return response.data.access_token;
}

app.post('/chat', async (req, res) => {
  try {
    const token = await getSalesforceToken();
    const response = await axios.post(
      `${process.env.SF_ORG_URL}/services/apexrest/nexaassist/v1/chat`,
      req.body,
      {
        headers: {
          Authorization: `Bearer ${token}`,
          'Content-Type': 'application/json',
        },
        timeout: 60000,
      }
    );
    const data = response.data;
    const showResolveButtons = data.message && data.message.includes('Did this resolve your issue');
    res.json({ ...data, showResolveButtons });
  } catch (error) {
    console.error('Error:', error.response?.data || error.message);
    res.status(500).json({ error: 'Something went wrong' });
  }
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`Velyza Middleware running on port ${PORT}`);
});