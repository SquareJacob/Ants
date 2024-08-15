#include <SDL.h>
#include <SDL_image.h>
#include <SDL_ttf.h>
#include <SDL_mixer.h>
#include <iostream>
#include <stdlib.h>  
#include <crtdbg.h>   //for malloc and free
#include <set>
#include "cuda_runtime.h"
#include "device_launch_parameters.h"
#include <stdio.h>
#define _CRTDBG_MAP_ALLOC
#ifdef _DEBUG
#define new new( _NORMAL_BLOCK, __FILE__, __LINE__)
#endif

SDL_Window* window;
SDL_Renderer* renderer;
bool running;
SDL_Event event;
std::set<std::string> keys;
std::set<std::string> currentKeys;
int mouseX = 0;
int mouseY = 0;
int mouseDeltaX = 0;
int mouseDeltaY = 0;
int mouseScroll = 0;
std::set<int> buttons;
std::set<int> currentButtons;
const int WIDTH = 800;
const int HEIGHT = 600;

void debug(int line, std::string file) {
	std::cout << "Line " << line << " in file " << file << ": " << SDL_GetError() << std::endl;
}

double random() {
	return static_cast<double>(rand()) / static_cast<double>(RAND_MAX);
}

__device__ double mod(double m, double n) {
	double result = m;
	if (result < 0) {
		while (result < 0) {
			result += n;
		}
	}
	else {
		while (result > n) {
			result -= n;
		}
	}
	return result;
}

const int BRUSHSIZE = 30;
const int MAXFOODPERPIXEL = 9999;
int food[HEIGHT * WIDTH] = { 0 };
const int WALLSIZE = 5;
int wall[HEIGHT * WIDTH] = { 0 }, *d_wall;
size_t allInts = sizeof(int) * static_cast<size_t>(WIDTH * HEIGHT);

//strength, angle
struct Pheremone {
	double strength = 0.0;
	double angle = 0.0;
};
Pheremone foodPheremones[HEIGHT * WIDTH], *d_foodPheremones;
Pheremone homePheremones[HEIGHT * WIDTH], *d_homePheremones;
size_t allPheremones = sizeof(Pheremone) * static_cast<size_t>(WIDTH * HEIGHT);

const int ANGLESAMPLES = 11;
const int LENGTHSAMPLES = 32;
double speed = 1.0;
double trailDecay = 0.001;
double strengthDecay = 0.0001;
double antDecay = 0.00;
double sensorDistance = 10.0;
double sensorAngle = M_PI / 4;
double rotateAmountMin = M_PI / 20;
double randomRotate = M_PI / 12;
const Uint32 red = 0x01000000, green = 0x00010000, blue = 0x00000100;
class Ant {
public:
	uint8_t r = 0, g = 0, b = 0;
	bool hasFood = false;
	double x = 0.0, y = 0.0, angle = 0.0, colonyX = 0.0, colonyY = 0.0, colonyRadius = 0.0, strength = 1.0;
	void setup() {
		double angle = random() * 2.0 * M_PI;
		x = colonyX + colonyRadius * cos(angle);
		y = colonyY + colonyRadius * sin(angle);
		this->angle = angle;
		strength = 0.0;
	}
	void draw(Uint32* pixel_ptr) {
		pixel_ptr[static_cast<int>(y) * WIDTH + static_cast<int>(x)] = red * r + green * g + blue * b + 255;
	}
	bool move() {
		angle += (2.0 * random() - 1.0) * randomRotate;
		double deltaX = speed * cos(angle);
		double deltaY = speed * sin(angle);
		if (0.0 < x + deltaX && x + deltaX < WIDTH && 0.0 < y + deltaY && y + deltaY < HEIGHT && wall[static_cast<int>(y + deltaY) * WIDTH + static_cast<int>(x+ deltaX)] == 0){
			x += deltaX;
			y += deltaY;
			if (strength > 0.0) {
				strength -= strengthDecay;
				if (strength < 0.0) {
					strength = 0.0;
				}
			}
			return true;
		}
		else if (wall[static_cast<int>(y) * WIDTH + static_cast<int>(x)] == 1) {
			setup();
		}
		else {
			angle += M_PI;
			//strength = 0.0;
			return false;
		}
	}
	void trail() {
		if (hasFood) {
			foodPheremones[static_cast<int>(y) * WIDTH + static_cast<int>(x)] = { strength, angle };
		}
		else {
			homePheremones[static_cast<int>(y) * WIDTH + static_cast<int>(x)] = { strength, angle };
			if (food[static_cast<int>(y) * WIDTH + static_cast<int>(x)] > 0) {
				food[static_cast<int>(y) * WIDTH + static_cast<int>(x)]--;
				hasFood = true;
				r = 255;
				b = 0;
				angle -= M_PI;
				strength = 1.0;
			}
		}
		if ((x - colonyX) * (x - colonyX) + (y - colonyY) * (y - colonyY) < colonyRadius * colonyRadius) {
			hasFood = false;
			r = 0;
			b = 255;
			angle += M_PI;
			strength = 1.0;
		}
	}
	__device__ void sense(int* wall, Pheremone* foodPheremones, Pheremone* homePheremones, double sensorAngle, double sensorDistance, double rotateAmountMin, double antDecay) {
		Pheremone* toUse;
		Pheremone sensors[ANGLESAMPLES];
		double lengths[ANGLESAMPLES];
		int indices[ANGLESAMPLES];
		if (hasFood) {
			toUse = homePheremones;
		}
		else {
			toUse = foodPheremones;
		}
		Pheremone current;
		double length, angle1;
		int x1, y1;
		for (int i = 0; i <	ANGLESAMPLES; i++) {
			angle1 = angle + sensorAngle * (2.0 * static_cast<float>(i) / static_cast<float>(ANGLESAMPLES - 1) - 1.0);
			for (int j = 0; j < LENGTHSAMPLES; j++) {
				length = static_cast<float>(j + 1) / static_cast<float>(LENGTHSAMPLES) * sensorDistance;
				x1 = static_cast<int>(x + length * cos(angle1));
				y1 = static_cast<int>(y + length * sin(angle1));
				if (wall[y1 * WIDTH + x1] == 1 || x1 < 0 || WIDTH < x1 || y1 < 0 || HEIGHT < y1) {
					break;
				}
				current = toUse[y1 * WIDTH + x1];
				if (current.strength > sensors[i].strength) {
					sensors[i].angle = current.angle;
					sensors[i].strength = current.strength;
					lengths[i] = static_cast<float>(j + 1) / static_cast<float>(LENGTHSAMPLES);
					indices[i] = y1 * WIDTH + x1;
				}
			}
		}
		double maxStrength = sensors[0].strength;
		for (int i = 1; i < ANGLESAMPLES; i++) {
			if (sensors[i].strength > maxStrength) {
				maxStrength = sensors[i].strength;
			}
		}

		if (maxStrength > 0.0) {
			double newAngle;
			double newLength;
			for (int i = 0; i < ANGLESAMPLES; i++) {
				if (sensors[i].strength == maxStrength) {
					newAngle = sensors[i].angle;
					newLength = lengths[i];
					toUse[indices[i]].strength -= antDecay;
					break;
				}
			}
			double rotateAmount = rotateAmountMin / newLength;
			angle = mod(angle, 2.0 * M_PI);
			newAngle = mod(newAngle + M_PI, 2.0 * M_PI);
			if (abs(angle - newAngle) < rotateAmount) {
				angle = newAngle;
			}
			else if (newAngle < angle) {
				if (angle - newAngle < M_PI) {
					angle -= rotateAmount;
				}
				else {
					angle += rotateAmount;
				}
			}
			else {
				if (newAngle - angle < M_PI) {
					angle += rotateAmount;
				}
				else {
					angle -= rotateAmount;
				}
			}
		}
	}
};

const int SQRTANTS = 159;
const int ANTS = SQRTANTS * SQRTANTS;
class Colony {
public:
	uint8_t r = 0, g = 0, b = 255;
	int radius = 15.0, x = WIDTH / 2, y = HEIGHT / 2;
	Ant ants[ANTS];
	void draw(Uint32* pixel_ptr) {
		for (int i = -radius; i <= radius; i++) {
			for (int j = -radius; j <= radius; j++) {
				if (i * i + j * j < radius * radius) {
					pixel_ptr[(y + j) * WIDTH + (x + i)] = red * r + green * g + blue * b + 255;
				}
			}
		}
	}
	void setup() {
		Ant* a;
		for (int i = 0; i < ANTS; i++) {
			a = &ants[i];
			a->r = r;
			a->g = g;
			a->b = b;
			a->colonyX = x;
			a->colonyY = y;
			a->colonyRadius = radius;
			a->setup();
		}
	}
};
Colony colony, * d_colony;
size_t s_colony = sizeof(colony);

__global__ void sense(Colony* colony, int* wall, Pheremone* foodPheremones, Pheremone* homePheremones, double sensorAngle, double sensorDistance, double rotateAmountMin, double antDecay) {
	colony->ants[threadIdx.x * SQRTANTS + blockIdx.x].sense(wall, foodPheremones, homePheremones, sensorAngle, sensorDistance, rotateAmountMin, antDecay);
}

int main(int argc, char* argv[]) {
	if (SDL_Init(SDL_INIT_EVERYTHING) == 0 && TTF_Init() == 0 && Mix_OpenAudio(44100, MIX_DEFAULT_FORMAT, 2, 2048) == 0) {
		//Setup
		window = SDL_CreateWindow("Window", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, WIDTH, HEIGHT, 0);
		if (window == NULL) {
			debug(__LINE__, __FILE__);
			return 0;
		}

		renderer = SDL_CreateRenderer(window, -1, 0);
		if (renderer == NULL) {
			debug(__LINE__, __FILE__);
			return 0;
		}
		srand(time(0));
		colony.setup();
		for (int i = 0; i < WIDTH * HEIGHT; i++) {
			food[i] = 0;
		}

		cudaSetDevice(0);
		cudaMalloc((void**)&d_colony, s_colony);
		cudaMalloc((void**)&d_wall, allInts);
		cudaMalloc((void**)&d_foodPheremones, allPheremones);
		cudaMalloc((void**)&d_homePheremones, allPheremones);

		SDL_Texture* texture = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_RGBA8888,
			SDL_TEXTUREACCESS_STREAMING, WIDTH, HEIGHT);
		void* txtPixels;
		int pitch;
		SDL_PixelFormat* format = SDL_AllocFormat(SDL_PIXELFORMAT_RGBA8888);
		Uint32* pixel_ptr;

		//Main loop
		running = true;
		bool playing = true;
		while (running) {
			//handle events
			for (std::string i : keys) {
				currentKeys.erase(i); //make sure only newly pressed keys are in currentKeys
			}
			for (int i : buttons) {
				currentButtons.erase(i); //make sure only newly pressed buttons are in currentButtons
			}
			mouseScroll = 0;
			while (SDL_PollEvent(&event)) {
				switch (event.type) {
				case SDL_QUIT:
					running = false;
					break;
				case SDL_KEYDOWN:
					if (!keys.contains(std::string(SDL_GetKeyName(event.key.keysym.sym)))) {
						currentKeys.insert(std::string(SDL_GetKeyName(event.key.keysym.sym)));
					}
					keys.insert(std::string(SDL_GetKeyName(event.key.keysym.sym))); //add keydown to keys set
					break;
				case SDL_KEYUP:
					keys.erase(std::string(SDL_GetKeyName(event.key.keysym.sym))); //remove keyup from keys set
					break;
				case SDL_MOUSEMOTION:
					mouseX = event.motion.x;
					mouseY = event.motion.y;
					mouseDeltaX = event.motion.xrel;
					mouseDeltaY = event.motion.yrel;
					break;
				case SDL_MOUSEBUTTONDOWN:
					if (!buttons.contains(event.button.button)) {
						currentButtons.insert(event.button.button);
					}
					buttons.insert(event.button.button);
					break;
				case SDL_MOUSEBUTTONUP:
					buttons.erase(event.button.button);
					break;
				case SDL_MOUSEWHEEL:
					mouseScroll = event.wheel.y;
					break;
				}
			}

			if (buttons.contains(1)) {
				for (int i = -BRUSHSIZE; i <= BRUSHSIZE; i++) {
					for (int j = -BRUSHSIZE; j <= BRUSHSIZE; j++) {
						if (i * i + j * j < BRUSHSIZE * BRUSHSIZE && 0 <= mouseX + i && mouseX + i <= WIDTH && 0 <= mouseY + j && mouseY + j <= HEIGHT) {
							food[(mouseY + j) * WIDTH + (mouseX + i)] = MAXFOODPERPIXEL;
						}
					}
				}
			}

			if (buttons.contains(3)) {
				for (int i = -WALLSIZE; i <= WALLSIZE; i++) {
					for (int j = -WALLSIZE; j <= WALLSIZE; j++) {
						if (i * i + j * j < WALLSIZE * WALLSIZE && 0 <= mouseX + i && mouseX + i <= WIDTH && 0 <= mouseY + j && mouseY + j <= HEIGHT) {
							wall[(mouseY + j) * WIDTH + (mouseX + i)] = 1;
						}
					}
				}
			}
			else if (buttons.contains(2)) {
				for (int i = -BRUSHSIZE; i <= BRUSHSIZE; i++) {
					for (int j = -BRUSHSIZE; j <= BRUSHSIZE; j++) {
						if (i * i + j * j < BRUSHSIZE * BRUSHSIZE && 0 <= mouseX + i && mouseX + i <= WIDTH && 0 <= mouseY + j && mouseY + j <= HEIGHT) {
							wall[(mouseY + j) * WIDTH + (mouseX + i)] = 0;
							food[(mouseY + j) * WIDTH + (mouseX + i)] = 0;
						}
					}
				}
			}

			if (currentKeys.contains("Space")) {
				playing = !playing;
			}

			Ant* a;
			if (playing) {
				for (int i = 0; i < WIDTH * HEIGHT; i++) {
					if (foodPheremones[i].strength > 0.0) {
						foodPheremones[i].strength -= trailDecay;
						if (foodPheremones[i].strength < 0.0) {
							foodPheremones[i].strength = 0.0;
						}
					}
					if (homePheremones[i].strength > 0.0) {
						homePheremones[i].strength -= trailDecay;
						if (homePheremones[i].strength < 0.0) {
							homePheremones[i].strength = 0.0;
						}
					}
				}

				for (int i = 0; i < ANTS; i++) {
					a = &colony.ants[i];
					if (a->move()) {
						a->trail();
					}
				}

				cudaMemcpy(d_colony, &colony, s_colony, cudaMemcpyHostToDevice);
				cudaMemcpy(d_wall, wall, allInts, cudaMemcpyHostToDevice);
				cudaMemcpy(d_foodPheremones, foodPheremones, allPheremones, cudaMemcpyHostToDevice);
				cudaMemcpy(d_homePheremones, homePheremones, allPheremones, cudaMemcpyHostToDevice);
				sense << <SQRTANTS, SQRTANTS >> > (d_colony, d_wall, d_foodPheremones, d_homePheremones, sensorAngle, sensorDistance, rotateAmountMin, antDecay);
				cudaDeviceSynchronize();
				cudaMemcpy(&colony, d_colony, s_colony, cudaMemcpyDeviceToHost);
				cudaMemcpy(wall, d_wall, allInts, cudaMemcpyDeviceToHost);
				cudaMemcpy(foodPheremones, d_foodPheremones, allPheremones, cudaMemcpyDeviceToHost);
				cudaMemcpy(homePheremones, d_homePheremones, allPheremones, cudaMemcpyDeviceToHost);
			}

			SDL_LockTexture(texture, NULL, &txtPixels, &pitch);
			pixel_ptr = (Uint32*)txtPixels;
			for (int i = 0; i < WIDTH * HEIGHT; i++) {
				if (wall[i] == 0) {
					pixel_ptr[i] = (food[i] * 255 / MAXFOODPERPIXEL) * green + 255;
				}
				else {
					pixel_ptr[i] = (red + green + blue) * 127 + 255;
				}
			}
			for (int i = 0; i < ANTS; i++) {
				colony.ants[i].draw(pixel_ptr);
			}
			colony.draw(pixel_ptr);
			SDL_UnlockTexture(texture);
			SDL_RenderCopy(renderer, texture, NULL, NULL);
			SDL_RenderPresent(renderer);
		}

		//Clean up
		cudaFree(d_colony);
		cudaFree(d_wall);
		cudaFree(d_foodPheremones);
		cudaFree(d_homePheremones);
		if (window) {
			SDL_DestroyWindow(window);
		}
		if (renderer) {
			SDL_DestroyRenderer(renderer);
		}
		TTF_Quit();
		Mix_Quit();
		IMG_Quit();
		SDL_Quit();
		return 0;
	}
	else {
		return 0;
	}
}