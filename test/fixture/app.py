"""Deliberately vulnerable sample for the action's self-test. Not for reuse."""

import subprocess

import yaml


def ping(host):
    # Command injection: user input reaches a shell.
    return subprocess.run("ping -c 1 " + host, shell=True, check=False)


def calculate(expression):
    # Code injection: arbitrary Python from the caller.
    return eval(expression)


def load_settings(text):
    # Unsafe deserialization: yaml.load without a safe loader.
    return yaml.load(text)
