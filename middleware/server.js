require('dotenv').config();
const express = require('express');
const axios = require('axios');
const cors = require('cors');

const app = express();
app.use(cors({
  origin: '*',
  methods: ['GET', 'POST', 'OPTIONS'],
  allowedHeaders: ['Content-Type', 'Authorization']
}));

app.options('*', cors());
app.use(express.json());

// Step 1 — Salesforce se Token Lo
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

// Step 2 — Frontend ki Call Suno aur Salesforce ko Forward Karo
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
    res.json(response.data);
  } catch (error) {
    console.error('Error:', error.response?.data || error.message);
    res.status(500).json({ error: 'Something went wrong' });
  }
});

// Server Start Karo
const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`Velyza Middleware running on port ${PORT}`);
});