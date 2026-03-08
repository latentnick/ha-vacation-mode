# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a data analysis project for home automation light usage patterns. The repository contains time-series data of light state changes exported from a home automation system (likely Home Assistant).

## Data Structure

### data.csv
- **Format**: CSV with 3 columns
- **Columns**:
  - `time`: ISO 8601 timestamp with timezone (Pacific Time)
  - `entity_id`: Light entity identifier (string)
  - `state.value`: Binary state ("0" = off, "1" = on)
- **Entities tracked**:
  - `office_main_lights`
  - `family_room_main_lights`
  - `play_room_upstairs_main_lights`
- **Date range**: Currently contains data from November 2025 through December 2025

## Development Environment

### Package Manager
Use `uv` as the Python package manager. Install packages with `uv add <package>` and run scripts with `uv run <script>`.

### Jupyter Notebook
The main analysis is done in `lights.ipynb`. To run:
- Ensure Jupyter is installed: `uv add jupyter` or `uv add jupyterlab`
- Launch: `uv run jupyter notebook` or `uv run jupyter lab`
- Open `lights.ipynb` in the browser interface

### Common Python Libraries for This Data
When performing analysis on this time-series data, commonly useful libraries include:
- `pandas` for data manipulation
- `matplotlib` or `seaborn` for visualization
- `datetime` for time-based analysis

## Data Analysis Context

The data represents binary state changes (on/off events) over time. Common analysis patterns:
- Time-series visualization of light usage
- Daily/weekly usage patterns
- Duration calculations (time between state changes)
- Simultaneous light usage analysis
- Peak usage time identification
